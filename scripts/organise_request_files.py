import yaml
import argparse
import sys
import os

trusted_owners = ['iuc']

def main():
    parser = argparse.ArgumentParser(description='Rewrite arbitrarily many tool.yml files as one file per tool revision')
    parser.add_argument('-o', '--output_path', help='Output file path')  # mandatory
    parser.add_argument('-f', '--files', help='Tool input files', nargs='+')  # mandatory unless --update_existing is true
    parser.add_argument(
        '--update_existing',
        help='If there are several toolshed entries for one name or name/revision entry uninstall all of them',
        action='store_true',
    )
    parser.add_argument('-s', '--source_directory', help='Directory containing tool yml files')

    args = parser.parse_args()

    files = args.files
    path = args.output_path
    update = args.update_existing
    source_dir = args.source_directory

    if not (files or source_dir):
        sys.stderr.write('either --files or --source_directory must be defined as an argument\n')
        return
    elif files and source_dir:
        sys.stderr.write('--files and --source_directory have both been provided.  Ignoring source_directory in favour of files\n')
    if source_dir and not files:
        files = ['%s/%s' % (source_dir, name) for name in os.listdir(source_dir)]

    tools_by_entry = []
    for file in files:
        with open(file) as input:
            content = yaml.safe_load(input.read())['tools']
            if isinstance(content, list):
                tools_by_entry += content
            else:
                tools_by_entry.append(content)

    if update:  # only update tools with trusted owners
        tools_by_entry = [t for t in tools_by_entry if t['owner'] in trusted_owners]
        # further filtering just for development
        for tool in tools_by_entry:
            for key in tool.keys():  # delete extraneous keys, we want latest revision
                if key not in ['name', 'owner', 'tool_panel_section_label', 'tool_shed_url']:
                    del tool[key]

    for tool in tools_by_entry:
        if 'revisions' in tool.keys() and len(tool['revisions']) > 1:
            for rev in tool['revisions']:
                new_tool = tool
                new_tool['revisions'] = [rev]
                write_output_file(path=path, tool=new_tool)
        else:
            write_output_file(path=path, tool=tool)


def write_output_file(path, tool):
    if not path[-1] == '/':
        path = path + '/'
    [revision] = tool['revisions'] if 'revisions' in tool.keys() else ['latest']
    file_path = '%s%s@%s.yml' % (path, tool['name'], revision)
    print('writing file ' + file_path)
    with open(file_path, 'w') as outfile:
        outfile.write(yaml.dump({'tools': [tool]}))


if __name__ == "__main__":
    main()
