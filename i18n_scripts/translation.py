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
    This function is the argument parser for this script.
    The script takes only one of the three arguments --split, --combine or --clean.
    Additionally, the --replace-underscore argument can only be used with --split.
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
    """
    Context manager to execute `os.chdir`.

    Usage:

    with change_directory('/some/path'):
      do_stuff_here()

    :param new_dir: Path
    """
    original_dir = os.getcwd()
    try:
        os.chdir(new_dir)
        yield
    finally:
        os.chdir(original_dir)


def get_modules_dir(override: Path = None) -> Path:
    """
    Gets the modules directory (repository root directory).
    """
    if override:
        return override

    return Path(__file__).absolute().parent.parent


def get_translation_file_path(modules_dir: Path, module_name, lang_dir, create_dirs=False):
    """
    Retrieves the path of the translation file for a specified module and language directory.

    Parameters:
        modules_dir (Path): The path to the base directory containing all the modules.
        module_name (str): The name of the module for which the translation path is being retrieved.
        lang_dir (str): The name of the language directory within the module's directory.
        create_dirs (bool): If True, creates the parent directories if they do not exist. Defaults to False.

    Returns:
        Path: The path to the module's translation file (Localizable.strings).
    """
    try:
        if module_name == MAIN_MODULE_NAME:
            # The main project structure is located into `OpenEdX` rather than `OpenEdX/OpenEdX`
            module_path = modules_dir / module_name
        else:
            # Rest of modules such as Core, Course, Dashboard, etc follow the `Dashboard/Dashboard` structure
            module_path = modules_dir / module_name / module_name

        lang_dir_path = module_path / lang_dir
        if create_dirs:
            lang_dir_path.mkdir(parents=True, exist_ok=True)
        return lang_dir_path / 'Localizable.strings'
    except Exception as e:
        print(f"Error creating directory path: {e}", file=sys.stderr)
        raise


def get_modules_to_translate(modules_dir: Path):
    """
    Retrieve the names of modules that have translation files for a specified language.

    Parameters:
        modules_dir (Path): The path to the directory containing all the modules.

    Returns:
        list of str: A list of module names that have translation files for the specified language.
    """
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
    """
    Retrieve the translations from all modules in the modules_dir.

    Parameters:
        modules_dir (Path): The directory containing the modules.

    Returns:
        dict: A dict containing a list of dictionaries containing the 'key', 'value', and 'comment' for each
        translation line. The key of the outer dict is the name of the module where the translations are going
        to be saved.
    """
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
    """
    Combine translation files from different modules into a single file.
    """
    try:
        modules_dir = get_modules_dir(override=modules_dir)
        translation = get_translations(modules_dir)
        write_translations_to_modules(modules_dir, 'en.lproj', translation)
    except Exception as e:
        print(f"Error combining translation files: {e}", file=sys.stderr)
        raise


def get_languages_dirs(modules_dir: Path):
    """
    Retrieve directories containing language files for translation.

    Args:
        modules_dir (Path): The directory containing all the modules.

    Returns:
        list: A list of directories containing language files for translation. Each directory represents
              a specific language and ends with the '.lproj' extension.
    """
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
    """
    Get translations from the translation file in the 'I18N' directory and distribute them into the appropriate
    modules' directories.

    Args:
        modules_dir (str): The directory containing all the modules.
        lang_dir (str): The directory containing the translation file being split.

    Returns:
        dict: A dictionary containing translations split by module.
    """
    translations = defaultdict(list)
    try:
        translations_file_path = get_translation_file_path(modules_dir, I18N_MODULE_NAME, lang_dir)
        if not translations_file_path.exists():
            return translations
            
        lang_list = localizable.parse_strings(filename=str(translations_file_path))
        for translation_entry in lang_list:
            # The combined I18N file uses the format "ModuleName.TranslationKey".
            # We split it to identify the destination module and restore the original key.
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
    """
    Write translations to language files for each module, merging with CustomLocalizable.strings if present.

    Merge Priority: 
    1. Check if a key exists in CustomLocalizable.strings.
    2. If yes, skip the version coming from the I18N/Community file to avoid duplicates.
    3. Append all Custom keys at the bottom of the file to ensure they take precedence.

    Args:
        modules_dir (str): The directory containing all the modules.
        lang_dir (str): The directory of the translation file being written.
        modules_translations (dict): A dictionary containing translations for each module.
    """
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

            # If a CustomLocalizable.strings file exists, parse it to handle overrides
            if custom_file_path.exists():
                print(f"  - [{lang_dir}] Merging custom overrides for: {module}")
                custom_list = localizable.parse_strings(filename=str(custom_file_path))

            custom_keys = {item['key'] for item in custom_list}

            with open(target_file_path, 'w') as f:
                f.write(f"/* Community Translations for {module} ({lang_dir}) */\n")
                community_count = 0
                for entry in community_list:
                    # Filter: Only write community translation if it isn't overridden by a custom key
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
    """
    Reverse the replacements performed by _unescape() in the localizable library
    """
    s = s.replace('\n', r'\n').replace('\r', r'\r').replace('"', r'\"')
    return s


def write_line_and_comment(f, entry):
    """
    Write a translation line with an optional comment to a file.

    Args:
        f (file object): The file object to write to.
        entry (dict): A dictionary containing the translation entry with 'key', 'value', and optional 'comment'.
    """
    comment = entry.get('comment')  # Retrieve the comment, if present
    if comment:
        f.write(f"/* {comment} */\n")
    f.write(f'"{entry["key"]}" = "{_escape(entry["value"])}";\n')


def split_translation_files(modules_dir=None):
    """
    Split translation files into separate files for each module and language.

    Args:
        modules_dir (str, optional): The directory containing all the modules. If not provided,
            it defaults to the parent directory of the directory containing this script.

    Returns:
        None
    """
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
    """
    Using a module_name return the pbxproj path.

    :param modules_dir:
    :param module_name:
    :return: Path
    """
    if module_name == MAIN_MODULE_NAME:
        return modules_dir / f'{module_name}.xcodeproj/project.pbxproj'
    return modules_dir / module_name / f'{module_name}.xcodeproj/project.pbxproj'


def get_xcode_projects(modules_dir: Path):
    """
    Return a list of module_name, xcode_project pairs.
    """
    for module_name in get_modules_to_translate(modules_dir):
        project_path = get_project_path(modules_dir, module_name)
        if project_path.exists():
            xcode_project = XcodeProject.load(project_path)
            yield module_name, xcode_project
        else:
            continue


def add_localizable(xcode_project: XcodeProject, localizable_relative_path: Path):
    """
    Add localizable file properly to the PBXVariantGroup.

    This function depends on the https://github.com/kronenthaler/mod-pbxproj/pull/356 implementation.

    TODO: Refactor to use the `master` version once either of the following issues is closed:
          - Issue by st3fan: https://github.com/kronenthaler/mod-pbxproj/issues/113
          - Proposal by OmarIthawi for Axim: https://github.com/kronenthaler/mod-pbxproj/pull/356

    :param xcode_project: XcodeProject
    :param localizable_relative_path: Path
    :return:
    """
    language, _rest = str(localizable_relative_path).split('.lproj')
    localizable_groups = xcode_project.get_groups_by_name(name='Localizable.strings', section='PBXVariantGroup')
    
    if not localizable_groups:
        # We need a single group. If many or none are found, it's a problem.
        return
    
    xcode_project.add_file(
        str(localizable_relative_path),
        name=language,
        parent=localizable_groups[0],
        force=False,
        tree=LOCALIZABLE_FILES_TREE,
        file_options=FileOptions(create_build_files=False),
    )


def add_translation_files_to_xcode(modules_dir: Path = None):
    """
    Add Localizable.strings files pulled from Transifex to XCode.
    """
    try:
        modules_dir = get_modules_dir(override=modules_dir)
        
        # 1. Handle Sub-Modules
        for module_name, xcode_project in get_xcode_projects(modules_dir):
            print(f'## Entering project: {module_name}')
            module_path = modules_dir / module_name
            project_files_path = module_path / module_name  # e.g. openedx-app-ios/Authorization/Authorization

            with change_directory(project_files_path):
                for path in list_translation_files(module_path):
                    add_localizable(xcode_project, path.relative_to(project_files_path))
            xcode_project.save()

        # 2. Handle Main Project (Used to specify which languages are supported by the app)
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
    """
    Remove translation files from the file system.

    :param xcode_project: XcodeProject
    :return:
    """
    try:
        modules_dir = get_modules_dir(override=modules_dir)
        for module_name, xcode_project in get_xcode_projects(modules_dir):
            module_path = modules_dir / module_name
            for path in list_translation_files(module_path):
                print(f'  - Removing "{path.name}" from file system')
                path.unlink()
            xcode_project.save()
    except Exception as e:
        print(f"Error cleaning files: {e}", file=sys.stderr)
        raise


def replace_underscores(modules_dir=None):
    """
    Replace Transifex underscore "ar_IQ" language code with iOS-compatible "ar-rIQ" codes.
    """
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
                    print(f"Renamed {old_path} to {new_path}")
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
    """
    List translation files in a given path.
    This method doesn't return the `en.lproj` translation source strings or custom overrides.
    """
    for localizable_abs_path in module_path.rglob('**/Localizable.strings'):
        # Don't return English files as they are source, not pulled translations
        # And skip the Custom override source files
        if localizable_abs_path.parent.name != 'en.lproj' and "CustomLocalizable" not in localizable_abs_path.name:
            yield localizable_abs_path


if __name__ == "__main__":
    main()
