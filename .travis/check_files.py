import argparse
import yaml
import sys

from bioblend.galaxy import GalaxyInstance
from bioblend.galaxy.tools import ToolClient


parser = argparse.ArgumentParser(description="Lint tool input files for installation on Galaxy")
parser.add_argument('-f', '--files', help='Tool input files', nargs='+')

args = parser.parse_args()
files = args.files

mandatory_keys = [
    'name', 'tool_panel_section_label', 'tool_shed_url', 'owner'
]

allowed_keys = ['revisions', 'ignore_test_errors']

forbidden_keys = ['tool_panel_section_id']  # this is unnecessary if we have allowed_keys check


loaded_files = []
for file in files:
    with open(file) as file_in:
        # As a first pass, check that yaml loads
        loaded_yml = yaml.safe_load(file_in.read()) # might throw exception here
        loaded_files.append({
            'yaml': loaded_yml,
            'filename': file,
        })

for loaded_file in loaded_files:
    sys.stderr.write('Checking %s ... ' % loaded_file['filename'])
    if not 'tools' in loaded_file['yaml'].keys():
        system.out.write('ERROR\n')
        raise Exception('Expecting .yml file with \'tools\'. Check requests/template/template.yml for an example.')
    tools = loaded_file['yaml']['tools']
    if not isinstance(tools, list):
        tools = [tools]
    for key in mandatory_keys:
        for tool in tools:
            if not key in tool.keys():
                system.out.write('ERROR\n')
                raise Exception('All tool list entries must have \'%s\' specified. Check requests/template/template.yml for an example.' % key)
        if key == 'tool_panel_section_label':
            pass # TODO: Check that section header is valid
            #

    sys.stderr.write('OK\n')

# Use bioblend to check whether the package is already installed.  Need to do this without
# making the API keys public

# galaxy_instance = GalaxyInstance(url=galaxy_url, key=galaxy_api_key)
# tool_client = ToolClient(galaxy_instance)
# panel = tool_client.get_tool_panel()
