import argparse
import os
import arrow
import yaml

from galaxy.util.tool_shed.xml_util import parse_xml
from galaxy.util import xml_to_string

from utils import (
    load_log,
    get_remote_file,
    copy_file_to_remote_location,
    get_toolshed_tools,
)

from pytz import timezone

"""
Copy shed_tool_conf.xml from a remote galaxy instance and update each tool with labels.  The
labels applied are from a yaml file stored in this repo, or 'new' and 'updated' labels for 
tools that have recently been installed.  The script copies the file over, updates the labels
in the xml and copies it back to where it started.  When running with the --safe argument
the original file will not be overwritten and will be copied back to its directory under
a new name to be reviewed by a human.
"""

date_format = 'DD/MM/YY HH:mm:ss'
arrow_parsable_date_format = 'YYYY-MM-DD HH:mm:ss'
aest = timezone('Australia/Queensland')

tool_labels_file = 'tool_panel/tool_labels.yml'
new_label = 'new'
updated_label = 'updated'


def main():
    parser = argparse.ArgumentParser(description='Update galaxy shed_tool_conf.xml with tool labels')
    parser.add_argument('-g', '--galaxy_url', help='Galaxy server URL', required=True)
    parser.add_argument('-u', '--remote_user', help='Remote user', default='galaxy')
    parser.add_argument('-f', '--remote_file_path', help='File name on galaxy', required=True)
    parser.add_argument('-k', '--key_path', help='Path to private ssh key file')  # for local testing - jenkins has the ssh identity already
    parser.add_argument('--display_new_days', type=int, help='Number of days to display label for new tool', required=True)
    parser.add_argument('--display_updated_days', type=int, help='Number of days to display label for updated tool', required=True)
    parser.add_argument('--safe', action='store_true', help='Do not overwrite the original file, give the updated file a new name')
    args = parser.parse_args()

    file = os.path.basename(args.remote_file_path)
    galaxy_url = args.galaxy_url
    display_new_days = args.display_new_days
    display_updated_days = args.display_updated_days

    copy_args = {
        'file': file,
        'remote_user': args.remote_user,
        'url': galaxy_url.split('//')[1] if galaxy_url.startswith('https://') else galaxy_url,
        'remote_file_path': args.remote_file_path,
        'key_path': args.key_path,
    }

    def filter_new(row):
        return row['Status'] == 'Installed' and in_time_window(row['Date (AEST)'], display_new_days) and row['New Tool'] == 'True'

    def filter_updated(row):
        return row['Status'] == 'Installed' and in_time_window(row['Date (AEST)'], display_updated_days) and row['New Tool'] == 'False'

    with open(tool_labels_file) as handle:
        tool_labels = yaml.safe_load(handle)
    
    tool_labels.update({
        new_label: [],
        updated_label: [],
    })

    toolshed_tools = get_toolshed_tools(galaxy_url)

    for row in load_log(filter=filter_new):
        tool_ids = [t['id'] for t in toolshed_tools if (
            t['tool_shed_repository']['name'] == row['Name']
            and t['tool_shed_repository']['owner'] == row['Owner']
            and t['tool_shed_repository']['changeset_revision'] == row['Installed Revision']
        )]
        tool_labels[new_label].extend(tool_ids)
    
    for row in load_log(filter=filter_updated):
        tool_ids = [t['id'] for t in toolshed_tools if (
            t['tool_shed_repository']['name'] == row['Name']
            and t['tool_shed_repository']['owner'] == row['Owner']
            and t['tool_shed_repository']['changeset_revision'] == row['Installed Revision']
        )]
        tool_labels[updated_label].extend(tool_ids)

    try:
        get_remote_file(**copy_args)
    except Exception as e:
        print(e)
        raise Exception('Failed to fetch remote file')

    tree, error_message = parse_xml(file)
    root = tree.getroot()
    # shed_tool_conf.xml has multiple section elements containing tools
    # loop through all sections and tools
    for section in root:
        if section.tag == 'section':
            for tool in section.getchildren():
                if tool.tag == 'tool':
                    tool_id = tool.find('id').text
                    # remove all existing labels
                    tool.attrib.pop('labels', None)
                     # replace labels from dict
                    labels_for_tool = []
                    for label in tool_labels:
                        for id in tool_labels[label]:
                            if tool_id == id or (
                                id.endswith('*') and get_deversioned_id(id) == get_deversioned_id(tool_id)
                            ):
                                labels_for_tool.append(label)
                                break
                    if labels_for_tool:
                        tool.set('labels', ','.join(labels_for_tool))


    with open(file, 'w') as handle:
        handle.write(xml_to_string(root, pretty=True))
    
    if args.safe:
        remote_file_path = copy_args['remote_file_path']
        copy_args.update({
            'remote_file_path': '%s_jenkins_%s' % (remote_file_path, arrow.now().format('YYYYMMDD'))
        })

    try:
        copy_file_to_remote_location(**copy_args)
    except Exception as e:
        print(e)
        raise Exception('Failed to copy file to remote instance')


def get_deversioned_id(tool_id):
    return '/'.join(tool_id.split('/')[:-1])


def in_time_window(time_str, days):
    # return True if time_str is less than a certain number of days ago
    converted_datetime = arrow.get(time_str, date_format).format(arrow_parsable_date_format)
    return arrow.get(converted_datetime, tzinfo=aest) > arrow.now().shift(days=-days)


if __name__ == "__main__":
    main()
