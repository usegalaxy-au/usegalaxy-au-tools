import argparse
import yaml
import sys

from bioblend import ConnectionError
from bioblend.galaxy import GalaxyInstance
from bioblend.galaxy.tools import ToolClient
from bioblend.toolshed import ToolShedInstance
from bioblend.toolshed.repositories import ToolShedRepositoryClient

default_tool_shed = 'toolshed.g2.bx.psu.edu'

mandatory_keys = ['name', 'tool_panel_section_label', 'owner']

# valid_section_labels = [
#     'Get Data', 'Send Data', 'Collection Operations', 'Text Manipulation',
#     'Filter and Sort', 'Join, Subtract and Group', 'FASTA/FASTQ',
#     'FASTQ Quality Control', 'SAM/BAM', 'BED', 'VCF/BCF', 'Nanopore',
#     'Convert Formats', 'Lift-Over', 'Operate on Genomic Intervals',
#     'Extract Features', 'Fetch Sequences/Alignments', 'Assembly', 'Annotation',
#     'Mapping', 'Variant Detection', 'Variant Calling', 'ChiP-seq', 'RNA-seq',
#     'Multiple Alignments', 'Bacterial Typing', 'Phylogenetics',
#     'Genome Editing', 'Mothur', 'Metagenomic analyses', 'Proteomics',
#     'Metabolomics', 'Picard', 'DeepTools', 'EMBOSS', 'Blast +',
#     'GATK Tools 1.4', 'GATK Tools', 'Alignment', 'RSeQC', 'Gemini Tools',
#     'Statistics',
# ]
#
# valid_section_ids = [
#     'getext', 'send', 'collection_operations', 'textutil', 'filter', 'group',
#     'fasta_fastq', 'fastq_qc', 'sam_bam', 'bed', 'vcf_bcf', 'nanopore',
#     'convert', 'liftOver', 'bxops', 'features', 'fetch_seq_align', 'assembly',
#     'annotation', 'mapping', 'ngs_variant_detection', 'variant_calling',
#     'chip_seq', 'rna_seq', 'multiple_alignments', 'typing', 'phylogenetics',
#     'genome_editing', 'mothur', 'metagenomics', 'proteomics', 'metabolomics',
#     'picard', 'deeptools', 'emboss', 'blast+', 'gatk', 'gatk2', 'alignment',
#     'rseqc', 'gemini_tools', 'stats',
# ]


def main():
    parser = argparse.ArgumentParser(description="Lint tool input files for installation on Galaxy")
    parser.add_argument('-f', '--files', help='Tool input files', nargs='+')
    parser.add_argument('-u', '--staging_url', help='Galaxy staging server URL')
    parser.add_argument('-k', '--staging_api_key', help='API key for galaxy staging server')
    parser.add_argument('-g', '--production_url', help='Galaxy production server URL')
    parser.add_argument('-a', '--production_api_key', help='API key for galaxy production server')

    args = parser.parse_args()
    files = args.files
    staging_url = args.staging_url
    staging_api_key = args.staging_api_key
    production_url = args.production_url
    production_api_key = args.production_api_key

    loaded_files = yaml_check(files)   # load yaml and raise ParserError if yaml is incorrect
    key_check(loaded_files)
    # label_check(loaded_files)
    tool_list = join_lists([x['yaml']['tools'] for x in loaded_files])
    installable_errors = check_installable(tool_list)
    installed_errors_staging = check_tools_against_panel(
        staging_url,
        staging_api_key,
        'staging',
        tool_list
    )
    installed_errors_production = check_tools_against_panel(
        production_url,
        production_api_key,
        'production',
        tool_list
    )

    all_warnings = installed_errors_staging  # If a tool is installed on staging but not production, do not raise an exception
    all_errors = installable_errors + installed_errors_production
    if all_errors:
        sys.stderr.write('\n')
        for error in all_errors:
            sys.stderr.write('Error %s\n' % error)
        raise Exception('Errors found')
    else:
        sys.stderr.write('All tools are installable and not already installed on %s\n' % production_url)


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
        for key in mandatory_keys:
            for tool in tools:
                if key not in tool.keys():
                    sys.stderr.write('ERROR\n')
                    raise Exception('Error in %s: All tool list entries must have \'%s\' specified. Check requests/template/template.yml for an example.' % (loaded_file['filename'], key))
            if key == 'tool_panel_section_label':
                pass  # TODO: Check that section label is valid

        sys.stderr.write('OK\n')


# def label_check(loaded_files):
#     for loaded_file in loaded_files:
#         sys.stderr.write('Checking %s \t ' % loaded_file['filename'])
#         tools = loaded_file['yaml']['tools']
#         for tool in tools:
#             label = tool['tool_panel_section_label']
#             if label not in valid_section_labels:
#                 raise Exception('Error in %s:  tool_panel_section_label %s is not valid' % (loaded_file['filename'], label))
#             id = tool.get('tool_panel_section_label')
#             if id and id not in valid_section_ids:
#                 raise Exception('Error in %s:  tool_panel_section_label %s is not valid' % (loaded_file['filename'], label))

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
                shed_status = 'online'
            except ConnectionError:
                if counter == 0:
                    print('Could not connect to toolshed %s\n' % url)
                shed_status = 'offline'
                # Raise an exception?  Ask Simon.

            if 'revisions' in tool.keys():  # Check that requested revisions are installable
                for revision in tool['revisions']:
                    if shed_status == 'online':
                        if revision not in installable_revisions:
                            errors.append('%s revision %s is not installable' % (tool['name'], revision))
                    tool.update({'revision_request_type': 'specific', 'shed_status': shed_status})
            else:
                if shed_status == 'online':
                    tool.update({'revisions': [installable_revisions[0]]})
                tool.update({'revision_request_type': 'latest', 'shed_status': shed_status})
    return errors


def check_tools_against_panel(galaxy_url, galaxy_api_key, server, tools):
    errors = []
    galaxy_instance = GalaxyInstance(url=galaxy_url, key=galaxy_api_key)
    tool_client = ToolClient(galaxy_instance)
    try:
        panel = tool_client.get_tool_panel()
    except ConnectionError:
        raise Exception('Unable to connect to galaxy instance %s' % galaxy_url)

    requested_tools = flatten_tool_list(tools)

    # the tool panel returned is a list of sections.
    # each section is a dict, dict['elems'] is a list of installed tools
    for section in [p for p in panel if 'elems' in p.keys()]:
        for elem in section['elems']:
            if 'tool_shed_repository' in elem.keys():
                repo = elem['tool_shed_repository']
                # tool is installed if 'name', 'owner' and 'revision' all match
                matching_tools = [tool for tool in requested_tools if tool['shed_status'] == 'online' and
                    (tool['name'], tool['owner'], tool['revisions'][0], tool['tool_shed_url']) ==
                    (repo['name'], repo['owner'], str(repo['changeset_revision']), repo['tool_shed'])
                ]
                if matching_tools:
                    tool = matching_tools[0]
                    errors.append(
                        'Tool with name: %s, owner: %s, revision: %s, tool_shed_url: %s is already installed on %s' %
                        (tool['name'], tool['owner'], tool['revisions'][0], tool['tool_shed_url'], galaxy_url)
                    )

    return errors


if __name__ == "__main__":
    main()
