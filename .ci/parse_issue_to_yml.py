

import sys
import subprocess
import yaml


def main(argv):
    issue_body = argv[0]
    url = extract_url(issue_body)
    tool = format_to_tool(url)
    tool = annotate_section_label(tool)
    write_yml(tool)
    cleanup()


def extract_url(issue_body):
    return issue_body.split('URL to the tool in the Galaxy Toolshed repository: ', 1)[1]


def format_to_tool(url):
    url = url.split('/')

    tool = {}
    tool['name'] = url[5]
    tool['owner'] = url[4]
    tool['revisions'] = url[6]
    tool['tool_shed_url'] = url[2]
    tool['tool_panel_section_label'] = ''
        
    return tool


def annotate_section_label(tool):
    # get galaxy_eu tools. Would be nice to do with bioblend? 
    subprocess.run(['get-tool-list', '-g', 'https://usegalaxy.eu', '-o', 'eu_tool_list.yaml'])

    with open('eu_tool_list.yaml', 'r') as fp:
        galaxy_eu_tools = yaml.safe_load(fp)

    for eu_tool in galaxy_eu_tools['tools']:
        if eu_tool['name'] == tool['name'] and eu_tool['owner'] == tool['owner']:
            tool['tool_panel_section_label'] = eu_tool['tool_panel_section_label']

    return tool


def write_yml(tool):
    with open(f'requests/tool_request_{tool["name"]}.yml', 'w') as fp:
        fp.write('tools:\n')
        fp.write(f'  - name: {tool["name"]}\n')
        fp.write(f'    owner: {tool["owner"]}\n')
        fp.write(f'    tool_panel_section_label: {tool["tool_panel_section_label"]}\n')
        fp.write(f'    tool_shed_url: {tool["tool_shed_url"]}\n')
        fp.write(f'    revisions:\n')
        fp.write(f'    - {tool["revisions"]}\n')


def cleanup():
    subprocess.run(['rm', 'eu_tool_list.yaml'])


if __name__ == '__main__':
    main(sys.argv[1:])