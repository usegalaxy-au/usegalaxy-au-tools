import yaml
import argparse
import os

from bioblend.galaxy import GalaxyInstance
from bioblend.galaxy.toolshed import ToolShedClient
from bioblend.toolshed import ToolShedInstance
from bioblend.toolshed.repositories import ToolShedRepositoryClient

trusted_owners_file = 'trusted_owners.yml'


def main():
    parser = argparse.ArgumentParser(description='Rewrite arbitrarily many tool.yml files as one file per tool revision')
    parser.add_argument('-o', '--output_path', help='Output file path')  # mandatory
    parser.add_argument('-f', '--files', help='Tool input files', nargs='+')  # mandatory unless --update_existing is true
    parser.add_argument('-g', '--production_url', help='Galaxy server URL')
    parser.add_argument('-a', '--production_api_key', help='API key for galaxy server')
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
    production_url = args.production_url
    production_api_key = args.production_api_key

    if not (files or source_dir):
        print('either --files or --source_directory must be defined as an argument\n')
        return
    elif files and source_dir:
        print('--files and --source_directory have both been provided.  Ignoring source_directory in favour of files\n')
    if source_dir and not files:
        files = ['%s/%s' % (source_dir, name) for name in os.listdir(source_dir)]

    tools = []
    for file in files:
        with open(file) as input:
            content = yaml.safe_load(input.read())['tools']
            if isinstance(content, list):
                tools += content
            else:
                tools.append(content)

    if update:  # update tools with trusted owners where updates are available
        if not production_url and production_api_key:
            raise Exception('--production_url and --production_api_key arguments are required when --update_exisiting flag is used')

        with open(trusted_owners_file) as infile:
            trusted_owners = yaml.safe_load(infile.read())['trusted_owners']

        # load repository data to check which tools have updates available
        galaxy_instance = GalaxyInstance(production_url, production_api_key)
        toolshed_client = ToolShedClient(galaxy_instance)
        repos = toolshed_client.get_repositories()
        installed_repos = [r for r in repos if r['status'] == 'Installed']  # Skip deactivated repos

        trusted_tools = [t for t in tools if [o for o in trusted_owners if t['owner'] == o['owner']] != []]
        print('Checking for updates from %d tools' % len(trusted_tools))
        tools = []
        for i, tool in enumerate(trusted_tools):
            if i > 0 and i % 100 == 0:
                print('%d/%d' % (i, len(trusted_tools)))
            new_revision_info = get_new_revision(tool, installed_repos, trusted_owners)
            # if tool_has_new_revision(tool, installed_repos, trusted_owners):
            if new_revision_info:
                extraneous_keys = [key for key in tool.keys() if key not in ['name', 'owner', 'tool_panel_section_label', 'tool_shed_url']]
                for key in extraneous_keys:
                    del tool[key]
                tool.update(new_revision_info)
                tools.append(tool)
        print('%d tools with updates available' % len(tools))

    for tool in tools:
        if 'revisions' in tool.keys() and len(tool['revisions']) > 1:
            for rev in tool['revisions']:
                new_tool = tool
                new_tool['revisions'] = [rev]
                write_output_file(path=path, tool=new_tool)
        else:
            write_output_file(path=path, tool=tool)


def get_new_revision(tool, repos, trusted_owners):
    matching_owners = [o for o in trusted_owners if tool['owner'] == o['owner']]
    if not matching_owners:
        return
    [owner] = matching_owners
    blacklist = owner.get('blacklist', []) if isinstance(owner, dict) else []
    blacklisted_revisions = [b.get('revision', 'all') for b in blacklist if b.get('name') == tool['name']]
    if 'all' in blacklisted_revisions:
        return

    toolshed = ToolShedInstance(url='https://' + tool['tool_shed_url'])
    repo_client = ToolShedRepositoryClient(toolshed)
    matching_repos = [r for r in repos if r['name'] == tool['name'] and r['owner'] == tool['owner']]
    if not matching_repos:
        return

    try:
        latest_revision = repo_client.get_ordered_installable_revisions(tool['name'], tool['owner'])[-1]
    except Exception as e:
        print('Skipping %s.  Error querying tool revisions: %s' % (tool['name'], str(e)))
        return

    blacklisted = latest_revision in blacklisted_revisions
    installed = latest_revision in [r['changeset_revision'] for r in matching_repos]
    if blacklisted or installed:
        return

    def get_version(revision):
        try:
            data = repo_client.get_repository_revision_install_info(tool['name'], tool['owner'], revision)
            repository, metadata, install_info = data
            version = metadata['valid_tools'][0]['version']
            return version
        except Exception as e:
            print('Skipping %s.  Error querying tool revisions: %s' % (tool['name'], str(e)))

    latest_revision_version = get_version(latest_revision)
    installed_versions = [get_version(r['changeset_revision']) for r in matching_repos]
    if latest_revision_version is None or None in installed_versions:  # skip on errors from get_version
        return
    skip_tests = latest_revision_version in installed_versions
    if skip_tests:
        print('Latest revision %s of %s has version %s already installed on GA.  Skipping tests for this tool ' % (
            latest_revision, tool['name'], latest_revision_version
        ))

    return {'revisions': [latest_revision], 'skip_tests': skip_tests}


def write_output_file(path, tool):
    if not path[-1] == '/':
        path = path + '/'
    [revision] = tool['revisions'] if 'revisions' in tool.keys() else ['latest']
    skip_tests = tool.pop('skip_tests', False)
    file_path = '%s%s@%s.yml' % (path, tool['name'], revision)
    print('writing file %s' % file_path)
    with open(file_path, 'w') as outfile:
        if skip_tests:
            outfile.write('# [SKIP_TESTS]\n')
        outfile.write(yaml.dump({'tools': [tool]}))


if __name__ == "__main__":
    main()
