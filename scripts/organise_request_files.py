import yaml
import argparse
import sys
import os

from bioblend.galaxy import GalaxyInstance
from bioblend.galaxy.toolshed import ToolShedClient
from bioblend.toolshed import ToolShedInstance
from bioblend.toolshed.repositories import ToolShedRepositoryClient as bioblend_ToolShedRepositoryClient

trusted_owners_file = 'trusted_owners.yml'


class ToolShedRepositoryClient(bioblend_ToolShedRepositoryClient):
    # Subclass bioblend object in order to access /updates endpoint
    def updates(self, name, owner, revision, hexlify=False):
        """
        Return a dictionary with boolean values for whether there are updates
        available for the repository revision, newer installable revisions
        available, the revision is the latest installable revision, and if the
        repository is deprecated.

        :type name: str
        :param name: the name of the repository

        :type owner: str
        :param owner: the owner of the repository

        :type revision: str
        :param revision: the revision to test updatability against

        :type hexlify: bool
        :param hexlify: whether to hexlify response

        :rtype: dict
        :return: Dict containing boolean values for keys
          'latest_installable_revision', 'revision_update', 'revision_upgrade',
          'repository_deprecated'
        """
        url = self.url + '/updates'
        params = {
            'name': name,
            'owner': owner,
            'changeset_revision': revision,
            'hexlify': hexlify,
        }
        r = self._get(url=url, params=params)

        return r


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
        sys.stderr.write('either --files or --source_directory must be defined as an argument\n')
        return
    elif files and source_dir:
        sys.stderr.write('--files and --source_directory have both been provided.  Ignoring source_directory in favour of files\n')
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
        gal = GalaxyInstance(production_url, production_api_key)
        cli = ToolShedClient(gal)
        u_repos = cli.get_repositories()

        trusted_tools = [t for t in tools if is_trusted_tool(trusted_owners, t)]
        sys.stderr.write('Checking for updates from %d tools\n' % len(trusted_tools))
        tools = []
        for i, tool in enumerate(trusted_tools):
            if i > 0 and i % 100 == 0:
                sys.stderr.write('%d/%d\n' % (i, len(trusted_tools)))
            if not latest_revision_installed(u_repos, tool):
                extraneous_keys = [key for key in tool.keys() if key not in ['name', 'owner', 'tool_panel_section_label', 'tool_shed_url']]
                for key in extraneous_keys:  # delete extraneous keys, we want latest revision
                    del tool[key]
                tools.append(tool)

    for tool in tools:
        if 'revisions' in tool.keys() and len(tool['revisions']) > 1:
            for rev in tool['revisions']:
                new_tool = tool
                new_tool['revisions'] = [rev]
                write_output_file(path=path, tool=new_tool)
        else:
            write_output_file(path=path, tool=tool)


def is_trusted_tool(trusted_owners, tool):
    trusted = False
    matching_owners = [o for o in trusted_owners if tool['owner'] == o['owner']]
    if matching_owners:
        [owner] = matching_owners
        blacklist = owner.get('blacklist') if isinstance(owner, dict) else None
        if not blacklist or tool['name'] not in blacklist:
            trusted = True
    return trusted


def latest_revision_installed(repos, tool):
    matching_repos = [r for r in repos if r['name'] == tool['name'] and r['owner'] == tool['owner'] and r['changeset_revision'] in tool['revisions']]
    toolshed = ToolShedInstance(url='https://' + tool['tool_shed_url'])
    repo_client = ToolShedRepositoryClient(toolshed)

    for mr in matching_repos:
        try:
            tool_shed_status = repo_client.updates(mr['name'], mr['owner'], mr['changeset_revision'])
        except Exception as e:
            sys.stderr.write('Skipping %s.  Error querying toolshed: %s\n' % (tool['name'], str(e)))
            return True  # return True so that update will be skipped.
        if tool_shed_status.get('latest_installable_revision') == 'True':
            return True
    return False


def write_output_file(path, tool):
    if not path[-1] == '/':
        path = path + '/'
    [revision] = tool['revisions'] if 'revisions' in tool.keys() else ['latest']
    file_path = '%s%s@%s.yml' % (path, tool['name'], revision)
    sys.stderr.write('writing file %s\n' % file_path)
    with open(file_path, 'w') as outfile:
        outfile.write(yaml.dump({'tools': [tool]}))


if __name__ == "__main__":
    main()
