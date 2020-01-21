import yaml
import argparse


def main():
    VERSION = 'development'

    parser = argparse.ArgumentParser(description='Rewrite arbitrarily many tool yml files as one file per tool revision')
    parser.add_argument('-o', '--output_path', help='Output file path')
    parser.add_argument('-f', '--files', help='Tool input files', nargs='+')

    args = parser.parse_args()

    files = args.files
    path = args.output_path

    tools_by_entry = []
    for file in files:
        with open(file) as input:
            content = yaml.safe_load(input.read())['tools']
            if isinstance(content, list):
                tools_by_entry += content
            else:
                tools_by_entry.append(content)

    for tool in tools_by_entry:
        if 'revisions' in tool.keys() and len(tool['revisions']) > 1:
            tool_revisions = []
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

if __name__ == "__main__": main()
