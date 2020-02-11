import argparse
import yaml
import sys

from bioblend import ConnectionError
from bioblend.toolshed import ToolShedInstance
from bioblend.toolshed.repositories import ToolShedRepositoryClient

default_tool_shed = 'toolshed.g2.bx.psu.edu'

mandatory_keys = ['name', 'tool_panel_section_label', 'owner']
forbidden_keys = ['tool_panel_section_id']

valid_section_labels = [
    'Get Data', 'Send Data', 'Collection Operations', 'Text Manipulation',
    'Filter and Sort', 'Join, Subtract and Group', 'FASTA/FASTQ',
    'FASTQ Quality Control', 'SAM/BAM', 'BED', 'VCF/BCF', 'Nanopore',
    'Convert Formats', 'Lift-Over', 'Operate on Genomic Intervals',
    'Extract Features', 'Fetch Sequences/Alignments', 'Assembly', 'Annotation',
    'Mapping', 'Variant Detection', 'Variant Calling', 'ChiP-seq', 'RNA-seq',
    'Multiple Alignments', 'Bacterial Typing', 'Phylogenetics',
    'Genome Editing', 'Mothur', 'Metagenomic analyses', 'Proteomics',
    'Metabolomics', 'Picard', 'DeepTools', 'EMBOSS', 'Blast +',
    'GATK Tools 1.4', 'GATK Tools', 'Alignment', 'RSeQC', 'Gemini Tools',
    'Statistics',
]


def main():
    parser = argparse.ArgumentParser(description="Lint tool input files for installation on Galaxy")
    parser.add_argument('-f', '--files', help='Tool input files', nargs='+')
    args = parser.parse_args()
    files = args.files

    loaded_files = yaml_check(files)   # load yaml and raise ParserError if yaml is incorrect
    key_check(loaded_files)
    tool_list = join_lists([x['yaml']['tools'] for x in loaded_files])
    installable_errors = check_installable(tool_list)

    if installable_errors:
        sys.stderr.write('\n')
        for error in installable_errors:
            sys.stderr.write('Error: %s\n' % error)
        raise Exception('Errors found')
    else:
        sys.stderr.write('\nAll tests have passed.')


def join_lists(list_of_lists):
    return [entry for list in list_of_lists for entry in list]


def flatten_tool_list(tool_list):
    flattened_tool_list = []
    for tool in tool_list:
        if 'revisions' in tool.keys():
            for revision in tool['revisions']:
                copy_of_tool = tool.copy()
                copy_of_tool['revisions'] = [revision]
                flattened_tool_list.append(copy_of_tool)
        else:
            copy_of_tool = tool.copy()
            flattened_tool_list.append(copy_of_tool)
    return flattened_tool_list


def yaml_check(files):
    loaded_files = []
    for file in files:
        with open(file) as file_in:
            # As a first pass, check that yaml loads
            try:
                loaded_yml = yaml.safe_load(file_in.read())  # might throw exception here
            except yaml.parser.ParserError as e:
                raise e
            loaded_files.append({
                'yaml': loaded_yml,
                'filename': file,
            })
    return loaded_files


def key_check(loaded_files):
    for loaded_file in loaded_files:
        sys.stderr.write('Checking %s \t ' % loaded_file['filename'])
        if 'tools' not in loaded_file['yaml'].keys():
            sys.stderr.write('ERROR\n')
            raise Exception('Error in %s: Expecting .yml file with \'tools\'. Check requests/template/template.yml for an example.' % loaded_file['filename'])
        tools = loaded_file['yaml']['tools']
        if not isinstance(tools, list):
            tools = [tools]
        for tool in tools:
            for key in mandatory_keys:
                if key not in tool.keys():
                    sys.stderr.write('ERROR\n')
                    raise Exception('Error in %s: All tool list entries must have \'%s\' specified. Check requests/template/template.yml for an example.' % (loaded_file['filename'], key))
            if 'tool_panel_section_id' in tool.keys():
                raise Exception('Error in %s: tool_panel_section_id must not be specified.  Use tool_panel_section_label only.')
            label = tool['tool_panel_section_label']
            if label not in valid_section_labels:
                raise Exception('Error in %s:  tool_panel_section_label %s is not valid' % (loaded_file['filename'], label))
        sys.stderr.write('OK\n')


def check_installable(tools):
    # Go through all tool_shed_url values in request files and run get_ordered_installable_revisions
    # to ascertain whether the specified revision is installable
    errors = []
    tools_by_shed = {}
    for tool in tools:
        if 'tool_shed_url' not in tool.keys():
            tool.update({'tool_shed_url': default_tool_shed})
        if tool['tool_shed_url'] in tools_by_shed.keys():
            tools_by_shed[tool['tool_shed_url']].append(tool)
        else:
            tools_by_shed[tool['tool_shed_url']] = [tool]

    for shed in tools_by_shed.keys():
        url = 'https://%s' % shed
        toolshed = ToolShedInstance(url=url)
        repo_client = ToolShedRepositoryClient(toolshed)

        for counter, tool in enumerate(tools_by_shed[shed]):
            try:
                installable_revisions = repo_client.get_ordered_installable_revisions(tool['name'], tool['owner'])
                if counter == 0:
                    sys.stderr.write('Connected to toolshed %s\n' % url)
                installable_revisions = [str(r) for r in installable_revisions][::-1]  # un-unicode and list most recent first
                # TODO make absolutely sure that the ordering is now correct
                if not installable_revisions:
                    errors.append('Tool with name: %s, owner: %s and tool_shed_url: %s has no installable revisions' % (tool['name'], tool['owner'], shed))
                    continue
            except ConnectionError:
                if counter == 0:
                    raise Exception('Could not connect to toolshed %s\n' % url)

            if 'revisions' in tool.keys():  # Check that requested revisions are installable
                for revision in tool['revisions']:
                    if revision not in installable_revisions:
                        errors.append('%s revision %s is not installable' % (tool['name'], revision))
            else:
                tool.update({'revisions': [installable_revisions[0]]})
    return errors


if __name__ == "__main__":
    main()
