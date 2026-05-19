#!/usr/bin/env python3
"""
This script performs two jobs:
 1- Combine the English translations from all modules in the repository to the I18N directory. After the English
    translation is combined, it will be pushed to the openedx-translations repository as described in OEP-58.
2- Split the pulled translation files from the openedx-translations repository into the iOS app modules and merge/overwrite them with CustomLocalizable.strings if it exists.

More detailed specifications are described in the docs/0002-atlas-translations-management.rst design doc.
"""

import argparse
import os
import re
import sys
from collections import defaultdict
from contextlib import contextmanager
from pathlib import Path

import localizable
from pbxproj import XcodeProject
from pbxproj.pbxextensions import FileOptions

LOCALIZABLE_FILES_TREE = '<group>'
MAIN_MODULE_NAME = 'OpenEdX'
I18N_MODULE_NAME = 'I18N'


def parse_arguments():
    parser = argparse.ArgumentParser(description='Split or Combine translations.')
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--split', action='store_true',
                       help='Split translations into separate files for each module and language.')
    group.add_argument('--combine', action='store_true',
                       help='Combine the English translations from all modules into a single file.')
    group.add_argument('--clean', action='store_true',
                       help='Remove translation files and clean XCode projects.')
    parser.add_argument('--replace-underscore', action='store_true',
                        help='Replace Transifex underscore "ar_IQ" language code with '
                             'iOS-compatible "ar-rIQ" codes (only with --split).')
    parser.add_argument('--add-xcode-files', action='store_true',
                        help='Add the language files to the XCode project (only with --split).')
    return parser.parse_args()


@contextmanager
def change_directory(new_dir: Path):
    original_dir = os.getcwd()
    try:
        os.chdir(new_dir)
        yield
    finally:
        os.chdir(original_dir)


def get_modules_dir(override: Path = None) -> Path:
    if override:
        return override
    return Path(__file__).absolute().parent.parent


def get_translation_file_path(modules_dir: Path, module_name, lang_dir, create_dirs=False):
    try:
        if module_name == MAIN_MODULE_NAME:
            module_path = modules_dir / module_name
        else:
            module_path = modules_dir / module_name / module_name

        lang_dir_path = module_path / lang_dir
        if create_dirs:
            lang_dir_path.mkdir(parents=True, exist_ok=True)
        return lang_dir_path / 'Localizable.strings'
    except Exception as e:
        print(f"Error creating directory path: {e}", file=sys.stderr)
        raise


def get_modules_to_translate(modules_dir: Path):
    try:
        modules_list = [
            module_dir for module_dir in os.listdir(modules_dir)
            if (
                (modules_dir / module_dir).is_dir()
                and os.path.isfile(get_translation_file_path(modules_dir, module_dir, 'en.lproj'))
                and module_dir != I18N_MODULE_NAME
                and module_dir != MAIN_MODULE_NAME
            )
        ]
        return modules_list
    except Exception as e:
        print(f"Error retrieving modules: {e}", file=sys.stderr)
        raise


def get_translations(modules_dir: Path):
    translations = []
    try:
        modules = get_modules_to_translate(modules_dir)
        for module in modules:
            translation_file = get_translation_file_path(modules_dir, module, lang_dir='en.lproj')
            module_translation = localizable.parse_strings(filename=translation_file)

            translations += [
                {
                    'key': f"{module}.{translation_entry['key']}",
                    'value': translation_entry['value'],
                    'comment': translation_entry['comment']
                } for translation_entry in module_translation
            ]
    except Exception as e:
        print(f"Error retrieving translations: {e}", file=sys.stderr)
        raise
    return {I18N_MODULE_NAME: translations}


def combine_translation_files(modules_dir=None):
    try:
        modules_dir = get_modules_dir(override=modules_dir)
        translation = get_translations(modules_dir)
        write_translations_to_modules(modules_dir, 'en.lproj', translation)
    except Exception as e:
        print(f"Error combining translation files: {e}", file=sys.stderr)
        raise


def get_languages_dirs(modules_dir: Path):
    try:
        lang_parent_dir = modules_dir / I18N_MODULE_NAME / I18N_MODULE_NAME
        languages_dirs = [
            directory for directory in os.listdir(lang_parent_dir)
            if directory.endswith('.lproj')
        ]
        if "en.lproj" not in languages_dirs:
            languages_dirs.append("en.lproj")
        return languages_dirs
    except Exception as e:
        print(f"Error finding language directories: {e}", file=sys.stderr)
        raise


def get_translations_from_file(modules_dir, lang_dir):
    translations = defaultdict(list)
    try:
        translations_file_path = get_translation_file_path(modules_dir, I18N_MODULE_NAME, lang_dir)
        if not translations_file_path.exists():
            return translations
            
        lang_list = localizable.parse_strings(filename=str(translations_file_path))
        for translation_entry in lang_list:
            if '.' in translation_entry['key']:
                module_name, key_remainder = translation_entry['key'].split('.', maxsplit=1)
                split_entry = {
                    'key': key_remainder,
                    'value': translation_entry['value'],
                    'comment': translation_entry['comment']
                }
                translations[module_name].append(split_entry)
    except Exception as e:
        print(f"Error extracting translations from file: {e}", file=sys.stderr)
        raise
    return translations


def write_translations_to_modules(modules_dir: Path, lang_dir, modules_translations):
    all_modules = set(get_modules_to_translate(modules_dir))
    all_modules.add(MAIN_MODULE_NAME)
    all_modules.update(modules_translations.keys())

    for module in all_modules:
        if module == I18N_MODULE_NAME: continue

        community_list = modules_translations.get(module, [])
        custom_list = []

        try:
            target_file_path = get_translation_file_path(modules_dir, module, lang_dir, create_dirs=True)
            custom_file_path = target_file_path.parent / 'CustomLocalizable.strings'

            if custom_file_path.exists():
                print(f"  - [{lang_dir}] Merging custom overrides for: {module}")
                custom_list = localizable.parse_strings(filename=str(custom_file_path))

            custom_keys = {item['key'] for item in custom_list}

            with open(target_file_path, 'w') as f:
                f.write(f"/* Community Translations for {module} ({lang_dir}) */\n")
                community_count = 0
                for entry in community_list:
                    if entry['key'] not in custom_keys:
                        write_line_and_comment(f, entry)
                        community_count += 1
                
                if community_count == 0 and not custom_list:
                    f.write("/* No community translations available */\n")

                if custom_list:
                    f.write(f"\n/* --- Custom Overrides for {module} --- */\n")
                    for entry in custom_list:
                        write_line_and_comment(f, entry)

        except Exception as e:
            print(f"Error writing to module {module}: {e}", file=sys.stderr)
            raise


def _escape(s):
    return s.replace('\n', r'\n').replace('\r', r'\r').replace('"', r'\"')


def write_line_and_comment(f, entry):
    comment = entry.get('comment')
    if comment:
        f.write(f"/* {comment} */\n")
    f.write(f'"{entry["key"]}" = "{_escape(entry["value"])}";\n')


def split_translation_files(modules_dir=None):
    try:
        modules_dir = get_modules_dir(override=modules_dir)
        languages_dirs = get_languages_dirs(modules_dir)
        for lang_dir in languages_dirs:
            print(f"Processing Language: {lang_dir}")
            translations = get_translations_from_file(modules_dir, lang_dir)
            write_translations_to_modules(modules_dir, lang_dir, translations)
    except Exception as e:
        print(f"Error splitting translation files: {e}", file=sys.stderr)
        raise


def get_project_path(modules_dir: Path, module_name: str) -> Path:
    if module_name == MAIN_MODULE_NAME:
        return modules_dir / f'{module_name}.xcodeproj/project.pbxproj'
    return modules_dir / module_name / f'{module_name}.xcodeproj/project.pbxproj'


def get_xcode_projects(modules_dir: Path):
    """
    MODIFIED: Added a check to skip modules that don't have an .xcodeproj file.
    """
    for module_name in get_modules_to_translate(modules_dir):
        project_path = get_project_path(modules_dir, module_name)
        if project_path.exists():
            xcode_project = XcodeProject.load(project_path)
            yield module_name, xcode_project
        else:
            # Skip logging for common folders that aren't standalone projects
            continue


def add_localizable(xcode_project: XcodeProject, localizable_relative_path: Path):
    language, _rest = str(localizable_relative_path).split('.lproj')
    localizable_groups = xcode_project.get_groups_by_name(name='Localizable.strings', section='PBXVariantGroup')
    if not localizable_groups: return
    
    xcode_project.add_file(
        str(localizable_relative_path),
        name=language,
        parent=localizable_groups[0],
        force=False,
        tree=LOCALIZABLE_FILES_TREE,
        file_options=FileOptions(create_build_files=False),
    )


def add_translation_files_to_xcode(modules_dir: Path = None):
    try:
        modules_dir = get_modules_dir(override=modules_dir)
        
        # 1. Handle Sub-Modules
        for module_name, xcode_project in get_xcode_projects(modules_dir):
            print(f'## Processing project: {module_name}')
            module_path = modules_dir / module_name
            project_files_path = module_path / module_name
            with change_directory(project_files_path):
                for path in list_translation_files(module_path):
                    add_localizable(xcode_project, path.relative_to(project_files_path))
            xcode_project.save()

        # 2. Handle Main Project
        print(f'## Processing project: {MAIN_MODULE_NAME}')
        main_project_path = get_project_path(modules_dir, MAIN_MODULE_NAME)
        if main_project_path.exists():
            main_project = XcodeProject.load(main_project_path)
            main_path = modules_dir / MAIN_MODULE_NAME
            with change_directory(main_path):
                for path in list_translation_files(main_path):
                    add_localizable(main_project, path.relative_to(main_path))
            main_project.save()
            
    except Exception as e:
        print(f"Error adding to XCode: {e}", file=sys.stderr)
        raise


def clean_translation_files(modules_dir: Path = None):
    try:
        modules_dir = get_modules_dir(override=modules_dir)
        for module_name, xcode_project in get_xcode_projects(modules_dir):
            module_path = modules_dir / module_name
            for path in list_translation_files(module_path):
                path.unlink()
            xcode_project.save()
    except Exception as e:
        print(f"Error cleaning files: {e}", file=sys.stderr)
        raise


def replace_underscores(modules_dir=None):
    try:
        modules_dir = get_modules_dir(override=modules_dir)
        languages_dirs = get_languages_dirs(modules_dir)
        for lang_dir in languages_dirs:
            old_path_rel = get_translation_file_path(modules_dir, I18N_MODULE_NAME, lang_dir)
            old_path = old_path_rel.parent
            if '_' in lang_dir:
                new_name = lang_dir.replace('_', '-')
                new_path = old_path.parent / new_name
                if old_path.exists():
                    os.rename(old_path, new_path)
    except Exception as e:
        print(f"Error replacing underscores: {e}", file=sys.stderr)
        raise


def main():
    args = parse_arguments()
    if args.split:
        if args.replace_underscore:
            replace_underscores()
        split_translation_files()
        if args.add_xcode_files:
            add_translation_files_to_xcode()
    elif args.combine:
        combine_translation_files()
    elif args.clean:
        clean_translation_files()


def list_translation_files(module_path: Path):
    for localizable_abs_path in module_path.rglob('**/Localizable.strings'):
        # Don't return English files as they are source, not pulled translations
        # And skip the Custom override source files
        if localizable_abs_path.parent.name != 'en.lproj' and "CustomLocalizable" not in localizable_abs_path.name:
            yield localizable_abs_path


if __name__ == "__main__":
    main()
