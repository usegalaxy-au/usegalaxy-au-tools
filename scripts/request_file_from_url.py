import argparse
import yaml

"""
Convert a toolshed link of the form
https://toolshed.g2.bx.psu.edu/view/iuc/snp_sites/5804f786060d
to a tool request file
"""


def tool_from_url(url, section_label=None):
    if url.startswith('https://'):
        url = url.split('//')[1]
    tool_shed_url, _, owner, name, revision = url.strip('/').split('/')
    tool = {
        'name': name,
        'owner': owner,
        'revisions': [revision],
        'tool_shed_url': tool_shed_url,
        'tool_panel_section_label': section_label or '?',
    }
    return tool


def main():
    parser = argparse.ArgumentParser(description='Convert toolshed links to shed-tools input format')
    parser.add_argument('-o', '--output_path', help='Output file path', default='requests/new_tools.yml')
    parser.add_argument('-f', '--file', help='File containing one toolshed link per line')
    parser.add_argument('-u', '--url', nargs='+', help='Toolshed link(s)')
    parser.add_argument('-s', '--section_label', help='Tool panel section label')

    args = parser.parse_args()
    if args.file and args.url:
        print('Error: --file (-f) and  --url (-u) are mutually exclusive options')
        return

    tools = []
    if args.url:
        for url in args.url:
            tools.append(tool_from_url(url, section_label=args.section_label))
    elif args.file:
        with open(args.file) as handle:
            for url in [line.strip() for line in handle.readlines() if line.strip()]:
                tools.append(tool_from_url(url, section_label=args.section_label))

    with open(args.output_path, 'w') as handle:
        yaml.dump({'tools': tools}, handle)


if __name__ == '__main__':
    main()
