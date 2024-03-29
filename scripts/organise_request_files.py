import yaml
import argparse
import os

from bioblend.galaxy import GalaxyInstance
from bioblend.toolshed import ToolShedInstance

trusted_owners_file = 'trusted_owners.yml'

"""
Preprocess files in shed-tools format, outputting one file per tool shed repository to install.  If the flag
--update_existing is used, look for new repositories based on the current lists of installed repositories
in --source_directory.
"""

def main():
    parser = argparse.ArgumentParser(description='Rewrite arbitrarily many tool.yml files as one file per tool revision')
    parser.add_argument('-o', '--output_path', help='Output directory path', required=True)
    parser.add_argument('-f', '--files', help='Tool input files', nargs='+')  # mandatory unless --update_existing is true
    parser.add_argument('-g', '--production_url', help='Galaxy server URL')
    parser.add_argument('-a', '--production_api_key', help='API key for galaxy server')
    parser.add_argument('--skip_list', help='List of tools to skip (one line per tool, <name>@<revision>)')
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
        files = [os.path.join(source_dir, name) for name in os.listdir(source_dir)]

    tools = []
    for file in files:
        with open(file) as input:
            content = yaml.safe_load(input.read())['tools']
            if isinstance(content, list):
                tools += content
            else:
                tools.append(content)  # TODO: is it ever not a list?

    if update:  # update tools with trusted owners where updates are available
        if not production_url and production_api_key:
            raise Exception('--production_url and --production_api_key arguments are required when --update_exisiting flag is used')

        with open(trusted_owners_file) as infile:
            trusted_owners = yaml.safe_load(infile.read())['trusted_owners']

        # load repository data to check which tools have updates available
        galaxy_instance = GalaxyInstance(production_url, production_api_key)
        repos = galaxy_instance.toolshed.get_repositories()
        installed_repos = [r for r in repos if r['status'] == 'Installed']  # Skip deactivated repos

        trusted_tools = [t for t in tools if t['owner'] in [entry['owner'] for entry in trusted_owners]]
        print('Checking for updates from %d tools' % len(trusted_tools))
        tools = []
        for i, tool in enumerate(trusted_tools):
            if i > 0 and i % 100 == 0:
                print('%d/%d' % (i, len(trusted_tools)))
            new_revision_info = get_new_revision(tool, installed_repos, trusted_owners)

            if new_revision_info:
                extraneous_keys = [key for key in tool.keys() if key not in ['name', 'owner', 'tool_panel_section_label', 'tool_shed_url']]
                for key in extraneous_keys:
                    del tool[key]
                tool.update(new_revision_info)
                tools.append(tool)
        print('%d tools with updates available' % len(tools))

    if args.skip_list:
        with open(args.skip_list) as handle:
            skip_list = [line.strip().split()[0] for line in handle.readlines() if line.strip()]
    else:
        skip_list = None

    for tool in tools:
        if 'revisions' in tool.keys():
            for rev in tool['revisions']:
                new_tool = tool
                new_tool['revisions'] = [rev]
                if not skip_list or '%s@%s' % (new_tool['name'], rev) not in skip_list:
                    write_output_file(path=path, tool=new_tool)
        else:
            write_output_file(path=path, tool=tool)


def get_new_revision(tool, repos, trusted_owners):
    matching_owners = [o for o in trusted_owners if tool['owner'] == o['owner']]
    if not matching_owners:
        return
    [owner] = matching_owners
    skipped_tools = owner.get('skip_tools', []) if isinstance(owner, dict) else []
    skipped_revisions = [st.get('revision', 'all') for st in skipped_tools if st.get('name') == tool['name']]
    if 'all' in skipped_revisions:
        return

    matching_repos = [r for r in repos if r['name'] == tool['name'] and r['owner'] == tool['owner']]
    if not matching_repos:
        return

    toolshed = ToolShedInstance(url='https://' + tool['tool_shed_url'])
    try:
        latest_revision = toolshed.repositories.get_ordered_installable_revisions(tool['name'], tool['owner'])[-1]
    except Exception as e:
        print('Skipping %s.  Error querying tool revisions: %s' % (tool['name'], str(e)))
        return

    skip_this_tool = latest_revision in skipped_revisions
    installed = latest_revision in [r['changeset_revision'] for r in matching_repos]
    if skip_this_tool or installed:
        return

    # Check whether the new revision updates tool versions on Galaxy.  If it does not, it will be installed
    # in place of the current latest revision on Galaxy and needs to be flagged as a version update so that
    # it will not be autoremoved in the instance of failing tests

    def get_installable_revision_for_revision(revision):
        # make a call to the toolshed to get a large blob of information about the repository
        # that includes the hash of the corresponding installable revision.
        try:
            data = toolshed.repositories.get_repository_revision_install_info(tool['name'], tool['owner'], revision)
            repository, metadata, install_info = data
            desc, clone_url, installable_revision, ctx_rev, owner, repo_deps, tool_deps = install_info[tool['name']]
        except Exception as e:  # KeyError, ValueError, bioblend.ConnectionError, return None
            print('Unexpected result querying install info for %s, %s, %s, returning None' % (tool['name'], tool['owner'], revision))
            return None
        return installable_revision

    latest_installed_revision = sorted(matching_repos, key=lambda x: int(x['ctx_rev']), reverse=True)[0]['changeset_revision']
    latest_installed_revision_installable_revision = get_installable_revision_for_revision(latest_installed_revision)
    if latest_installed_revision_installable_revision is None:
        return  # skip on errors from revision query
    version_update = latest_installed_revision_installable_revision == latest_revision
    if version_update:
        print('Latest revision %s of %s is a version update of installed revision %s.  Skipping tests for this tool ' % (
            latest_revision, tool['name'], latest_installed_revision
        ))
    return {'revisions': [latest_revision], 'version_update': version_update}


def write_output_file(path, tool):
    [revision] = tool['revisions'] if 'revisions' in tool.keys() else ['latest']
    version_update = tool.pop('version_update', False)
    file_path = os.path.join(path, '%s@%s.yml' % (tool['name'], revision))
    print('writing file %s' % file_path)
    with open(file_path, 'w') as outfile:
        if version_update:
            outfile.write('# [VERSION_UPDATE]\n')
        outfile.write(yaml.dump({'tools': [tool]}))


if __name__ == "__main__":
    main()
