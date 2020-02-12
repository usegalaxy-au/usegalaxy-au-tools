from bioblend.galaxy import GalaxyInstance
from bioblend.galaxy.toolshed import ToolShedClient
import argparse
import yaml
import os
import sys

"""
Uninstall tools from a galaxy instance via the API using the bioblend package.
This can be used to uninstall any galaxy toolshed tool.  The main use case is
when a tool has been installed incorrectly or when an error has occurred during
installation causing the tool to be partially installed.
"""


def main():
    parser = argparse.ArgumentParser(description='Uninstall tool from a galaxy instance')
    parser.add_argument('-g', '--galaxy_url', help='Galaxy server URL')
    parser.add_argument('-a', '--api_key', help='API key for galaxy server')
    parser.add_argument(
        '-n',
        '--names',
        help='Names of tools to uninstall.  These can include revision hashes e.g. --names name1@revision1 name1@revision2 name2 ',
        nargs='+',
    )
    parser.add_argument(
        '-f',
        '--force',
        help='If there are several toolshed entries for one name or name/revision entry uninstall all of them',
        action='store_true',
    )

    args = parser.parse_args()
    galaxy_url = args.galaxy_url
    api_key = args.api_key
    names = args.names
    force = args.force

    if not names:
        raise Exception('Arguments --names (-n) must be provided.')

    uninstall_tools(galaxy_url, api_key, names, force)


def uninstall_tools(galaxy_server, api_key, names, force):
    galaxy_instance = GalaxyInstance(url=galaxy_server, key=api_key)
    toolshed_client = ToolShedClient(galaxy_instance)

    temp_tool_list_file = 'tmp/installed_tool_list.yml'
    # TODO: Switch to using bioblend to obtain this list
    # ephemeris uses bioblend but without using ephemeris we cut out the need to for a temp file
    os.system('get-tool-list -g %s -a %s -o %s --get_all_tools' % (galaxy_server, api_key, temp_tool_list_file))

    tools_to_uninstall = []
    with open(temp_tool_list_file) as tool_file:
        installed_tools = yaml.safe_load(tool_file.read())['tools']
    if not installed_tools:
        raise Exception('No tools to uninstall')
    os.system('rm %s' % temp_tool_list_file)

    for name in names:
        revision = None
        if '@' in name:
            (name, revision) = name.split('@')
        matching_tools = [t for t in installed_tools if t['name'] == name and (not revision or revision in t['revisions'])]
        if len(matching_tools) == 0:
            id_string = 'name %s revision %s' % (name, revision) if revision else 'name %s' % name
            sys.stderr.write('*** Warning: No tool with %s\n' % id_string)
        elif len(matching_tools) > 1 and not force:
            sys.stderr.write(
                '*** Warning: More than one toolshed tool found for %s.  ' % name
                + 'Not uninstalling any of these tools.  Run script with --force (-f) flag to uninstall anyway\n'
            )
        else:  # Either there is only one matching tool for the name and revision, or there are many and force=True
            for tool in matching_tools:
                tool_copy = tool.copy()
                if revision:
                    tool_copy['revisions'] = [revision]
                tools_to_uninstall.append(tool_copy)

    for tool in tools_to_uninstall:
        try:
            name = tool['name']
            owner = tool['owner']
            tool_shed_url = tool['tool_shed_url']
            revision = tool['revisions'][0]
            sys.stderr.write('Uninstalling %s at revision %s\n' % (name, revision))
            return_value = toolshed_client.uninstall_repository_revision(name=name, owner=owner, changeset_revision=revision, tool_shed_url=tool_shed_url)
            sys.stderr.write(str(return_value) + '\n')
        except KeyError as e:
            sys.stderr.write(e)


if __name__ == "__main__":
    main()
