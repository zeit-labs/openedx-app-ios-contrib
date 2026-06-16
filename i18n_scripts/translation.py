#!/usr/bin/env python3
"""
This script performs two jobs:
 1- Combine the English translations from all modules in the repository to the I18N directory. After the English
    translation is combined, it will be pushed to the openedx-translations repository as described in OEP-58.
 2- Split the pulled translation files from the openedx-translations repository into the iOS app modules 
    and merge/overwrite them with CustomLocalizable.strings if it exists.

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
    """
    Argument parser for the script.
    """
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
    """Context manager to execute os.chdir."""
    original_dir = os.getcwd()
    try:
        os.chdir(new_dir)
        yield
    finally:
        os.chdir(original_dir)


def get_modules_dir(override: Path = None) -> Path:
    """Gets the modules directory (repository root directory)."""
    return override if override else Path(__file__).absolute().parent.parent


def get_translation_file_path(modules_dir: Path, module_name, lang_dir, create_dirs=False):
    """Retrieves the path of the Localizable.strings file for a specific module."""
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
    """Retrieve module names that have English translation files."""
    try:
        return [
            module_dir for module_dir in os.listdir(modules_dir)
            if (
                (modules_dir / module_dir).is_dir()
                and os.path.isfile(get_translation_file_path(modules_dir, module_dir, 'en.lproj'))
                and module_dir not in [I18N_MODULE_NAME, MAIN_MODULE_NAME]
            )
        ]
    except Exception as e:
        print(f"Error listing modules: {e}", file=sys.stderr)
        raise


def get_translations(modules_dir: Path):
    """Retrieve English translations from all modules and prefix keys with module name."""
    translations = []
    try:
        modules = get_modules_to_translate(modules_dir)
        for module in modules:
            translation_file = get_translation_file_path(modules_dir, module, lang_dir='en.lproj')
            module_translation = localizable.parse_strings(filename=str(translation_file))

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
    """Job 1: Combine all module English strings into the I18N master file."""
    try:
        modules_dir = get_modules_dir(override=modules_dir)
        translation = get_translations(modules_dir)
        # We explicitly write to en.lproj for the combined file
        write_translations_to_modules(modules_dir, 'en.lproj', translation, is_combine=True)
    except Exception as e:
        print(f"Error combining translation files: {e}", file=sys.stderr)
        raise


def get_languages_dirs(modules_dir: Path, include_english=False):
    """Retrieve .lproj directories from the I18N folder."""
    try:
        lang_parent_dir = modules_dir / I18N_MODULE_NAME / I18N_MODULE_NAME
        if not lang_parent_dir.exists():
            return []
        
        languages = [
            directory for directory in os.listdir(lang_parent_dir)
            if directory.endswith('.lproj')
        ]
        
        if not include_english and "en.lproj" in languages:
            languages.remove("en.lproj")
            
        return languages
    except Exception as e:
        print(f"Error getting language directories: {e}", file=sys.stderr)
        raise


def get_translations_from_file(modules_dir, lang_dir):
    """Read the master I18N file and group strings by module name."""
    translations = defaultdict(list)
    try:
        translations_file_path = get_translation_file_path(modules_dir, I18N_MODULE_NAME, lang_dir)
        if not translations_file_path.exists():
            return translations
            
        lang_list = localizable.parse_strings(filename=str(translations_file_path))
        for translation_entry in lang_list:
            if '.' in translation_entry['key']:
                module_name, key_remainder = translation_entry['key'].split('.', maxsplit=1)
                translations[module_name].append({
                    'key': key_remainder,
                    'value': translation_entry['value'],
                    'comment': translation_entry['comment']
                })
    except Exception as e:
        print(f"Error extracting translations from master file: {e}", file=sys.stderr)
        raise
    return translations


def write_translations_to_modules(modules_dir: Path, lang_dir, modules_translations, is_combine=False):
    """
    Writes translations to files. 
    If is_combine is True: writes the master file in I18N.
    If is_combine is False: splits strings into modules and merges with CustomLocalizable.strings.
    """
    if is_combine:
        targets = [I18N_MODULE_NAME]
    else:
        targets = set(get_modules_to_translate(modules_dir))
        targets.add(MAIN_MODULE_NAME)
        targets.update(modules_translations.keys())

    for module in targets:
        # Skip I18N if we are in split mode (handled by is_combine logic)
        if not is_combine and module == I18N_MODULE_NAME:
            continue

        community_list = modules_translations.get(module, [])
        custom_list = []

        try:
            target_file_path = get_translation_file_path(modules_dir, module, lang_dir, create_dirs=True)
            
            # Merge Logic: Only apply for app modules during split phase
            if not is_combine:
                custom_file_path = target_file_path.parent / 'CustomLocalizable.strings'
                if custom_file_path.exists():
                    print(f"  - [{lang_dir}] Merging custom overrides for: {module}")
                    custom_list = localizable.parse_strings(filename=str(custom_file_path))

            custom_keys = {item['key'] for item in custom_list}

            with open(target_file_path, 'w') as f:
                if is_combine:
                    f.write(f"/* Combined English Source for Open edX iOS */\n")
                else:
                    f.write(f"/* Community Translations for {module} ({lang_dir}) */\n")
                
                written_count = 0
                for entry in community_list:
                    if entry['key'] not in custom_keys:
                        write_line_and_comment(f, entry)
                        written_count += 1
                
                if written_count == 0 and not custom_list:
                    f.write("/* No translations available */\n")

                if custom_list:
                    f.write(f"\n/* --- Custom Overrides for {module} --- */\n")
                    for entry in custom_list:
                        write_line_and_comment(f, entry)

        except Exception as e:
            print(f"Error writing to {module}: {e}", file=sys.stderr)
            raise


def _escape(s):
    """Escapes newlines and quotes for .strings format."""
    return s.replace('\n', r'\n').replace('\r', r'\r').replace('"', r'\"')


def write_line_and_comment(f, entry):
    """Writes a standard Localizable.strings entry."""
    comment = entry.get('comment')
    if comment:
        f.write(f"/* {comment} */\n")
    f.write(f'"{entry["key"]}" = "{_escape(entry["value"])}";\n')


def split_translation_files(modules_dir=None):
    """Job 2: Distribute translations from I18N to modules."""
    try:
        modules_dir = get_modules_dir(override=modules_dir)
        languages_dirs = get_languages_dirs(modules_dir)
        for lang_dir in languages_dirs:
            print(f"Processing Language: {lang_dir}")
            translations = get_translations_from_file(modules_dir, lang_dir)
            write_translations_to_modules(modules_dir, lang_dir, translations, is_combine=False)
    except Exception as e:
        print(f"Error splitting translation files: {e}", file=sys.stderr)
        raise


def get_project_path(modules_dir: Path, module_name: str) -> Path:
    if module_name == MAIN_MODULE_NAME:
        return modules_dir / f'{module_name}.xcodeproj/project.pbxproj'
    return modules_dir / module_name / f'{module_name}.xcodeproj/project.pbxproj'


def get_xcode_projects(modules_dir: Path):
    for module_name in get_modules_to_translate(modules_dir):
        path = get_project_path(modules_dir, module_name)
        if path.exists():
            yield module_name, XcodeProject.load(path)


def add_localizable(xcode_project: XcodeProject, localizable_relative_path: Path):
    language = str(localizable_relative_path).split('.lproj')[0]
    groups = xcode_project.get_groups_by_name(name='Localizable.strings', section='PBXVariantGroup')
    if not groups:
        return
    
    xcode_project.add_file(
        str(localizable_relative_path),
        name=language,
        parent=groups[0],
        force=False,
        tree=LOCALIZABLE_FILES_TREE,
        file_options=FileOptions(create_build_files=False),
    )


def add_translation_files_to_xcode(modules_dir: Path = None):
    """Programmatically add the newly created .strings files to Xcode projects."""
    try:
        modules_dir = get_modules_dir(override=modules_dir)
        for module_name, xcode_project in get_xcode_projects(modules_dir):
            print(f'## Adding files to Xcode project: {module_name}')
            module_path = modules_dir / module_name
            project_files_path = module_path / module_name

            with change_directory(project_files_path):
                for path in list_translation_files(module_path):
                    add_localizable(xcode_project, path.relative_to(project_files_path))
            xcode_project.save()

        # Handle Main Project
        main_proj_path = get_project_path(modules_dir, MAIN_MODULE_NAME)
        if main_proj_path.exists():
            print(f'## Adding files to Xcode project: {MAIN_MODULE_NAME}')
            main_project = XcodeProject.load(main_proj_path)
            main_path = modules_dir / MAIN_MODULE_NAME
            with change_directory(main_path):
                for path in list_translation_files(main_path):
                    add_localizable(main_project, path.relative_to(main_path))
            main_project.save()
    except Exception as e:
        print(f"Error updating Xcode projects: {e}", file=sys.stderr)
        raise


def clean_translation_files(modules_dir: Path = None):
    """Remove all non-English translation files."""
    try:
        modules_dir = get_modules_dir(override=modules_dir)
        # Search all modules
        all_modules = get_modules_to_translate(modules_dir) + [MAIN_MODULE_NAME]
        for module in all_modules:
            module_path = modules_dir / module
            for path in list_translation_files(module_path):
                print(f'  - Deleting: {path.relative_to(modules_dir)}')
                path.unlink()
    except Exception as e:
        print(f"Error cleaning files: {e}", file=sys.stderr)
        raise


def replace_underscores(modules_dir=None):
    """Rename ar_IQ.lproj to ar-IQ.lproj for iOS compatibility."""
    try:
        modules_dir = get_modules_dir(override=modules_dir)
        # Check folders in I18N
        parent = modules_dir / I18N_MODULE_NAME / I18N_MODULE_NAME
        for lang_dir in os.listdir(parent):
            if '_' in lang_dir and lang_dir.endswith('.lproj'):
                old_path = parent / lang_dir
                new_path = parent / lang_dir.replace('_', '-')
                os.rename(old_path, new_path)
                print(f"Renamed locale folder: {lang_dir} -> {new_path.name}")
    except Exception as e:
        print(f"Error replacing underscores: {e}", file=sys.stderr)
        raise


def list_translation_files(module_path: Path):
    """Returns all Localizable.strings except English source and Custom overrides."""
    for path in module_path.rglob('**/Localizable.strings'):
        if path.parent.name != 'en.lproj' and "CustomLocalizable" not in path.name:
            yield path


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


if __name__ == "__main__":
    main()
