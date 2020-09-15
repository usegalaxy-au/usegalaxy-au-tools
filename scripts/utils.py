import csv
import subprocess

from bioblend.galaxy import GalaxyInstance
from bioblend.toolshed import ToolShedInstance


def get_galaxy_instance(url, api_key=None):
    if not url.startswith('https://'):
        url = 'https://' + url
    return GalaxyInstance(url, api_key)

def get_toolshed_instance(url):
    if not url.startswith('https://'):
        url = 'https://' + url
    return ToolShedInstance(url=url)

def get_repositories(url, api_key):
    galaxy = get_galaxy_instance(url, api_key)
    return galaxy.toolshed.get_repositories()


def get_toolshed_tools(url, api_key=None):
    galaxy = get_galaxy_instance(url, api_key)
    return [tool for tool in galaxy.tools.get_tools() if tool.get('tool_shed_repository')]


def load_log(filter=None):
    """
    Load the installation log tsv file and return it as a list row objects, i.e.
    [{'Build Num.': '156', 'Name': 'abricate', ...}, {'Build Num.': '156', 'Name': 'bedtools', ...},...]
    The filter argument is a function that takes a row as input and returns True or False
    """
    log_file = 'automated_tool_installation_log.tsv'
    table = []
    with open(log_file) as tsvfile:
        reader = csv.DictReader(tsvfile, dialect='excel-tab')
        for row in reader:
            if not filter or filter(row):
                table.append(row)
    return table


def get_valid_tools_for_repo(name, owner, revision, tool_shed_url):
    toolshed = get_toolshed_instance(tool_shed_url)
    data = toolshed.repositories.get_repository_revision_install_info(name, owner, revision)
    repository, metadata, install_info = data
    return metadata.get('valid_tools')


def get_remote_file(file, remote_file_path, url, remote_user, key_path=None):
    key_arg = '' if not key_path else '-i %s' % key_path
    command = 'scp %s %s@%s:%s %s' % (key_arg, remote_user, url, remote_file_path, file)
    subprocess.check_output(command, shell=True)


def copy_file_to_remote_location(file, remote_file_path, remote_user, url, key_path=None):
    key_arg = '' if not key_path else '-i %s' % key_path
    command = 'scp %s %s %s@%s:%s' % (key_arg, file, remote_user, url, remote_file_path)
    subprocess.check_output(command, shell=True)
