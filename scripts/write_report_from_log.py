import csv
import sys
import argparse

default_tool_shed = 'toolshed.g2.bx.psu.edu'
log_file = 'automated_tool_installation_log.tsv'

"""
Generate a report of weekly installations and updates on Galaxy Australia
Because this script runs at the end of the update cron job and the length
of the job may vary, we need to include only installations completed between
now and the time that this script was run last week
"""

parser = argparse.ArgumentParser(description='Generate report from installation log')
parser.add_argument('-j', '--jenkins_build_number', help='Build Number of current job if running with Jenkins')
parser.add_argument('-o', '--outfile', help='Name of report file to write')
parser.add_argument('-d', '--date', help='Date for report header')
parser.add_argument('-b', '--begin_build', help='Jenkins build in log to use as first in report, i.e. install-7 or update-3')
parser.add_argument('-e', '--end_build', help='Jenkins build in log to use as last in report, i.e. install-10 or update-6.  Default is end of file')

style = """\n<style>
  table {
    width: 100%;
    margin: 10px 20px;
  }
  table th {
    display: none;
  }
  td {
    padding: 3px 5px;
  }
  tr td:nth-child(1) {
    vertical-align: top;
    width: 25%;
  }
</style>\n"""


def get_report_header(date):
    return (
        '---\n'
        'site: freiburg\n'
        'title: \'Galaxy Australia tool updates %s\'\n'
        'tags: [tools]\n'
        'supporters:\n'
        '    - galaxyaustralia\n'
        '    - melbinfo\n'
        '    - qcif\n'
        '---\n\n' % date
    )


def get_build_range(table, build_category, build_number):
    rows = [
        row_num for (row_num, row) in enumerate(table) if row['Category'] == build_category.title() and row['Build Num.'] == str(build_number)
    ]
    return (rows[0], rows[-1])


def tool_table(tool_dict):
    content = '| Section | Tool |\n|---------|-----|\n'
    for section in sorted(tool_dict.keys()):
        content += '| **%s** | %s |\n' % (
            section,
            '<br/>'.join(['%s %s' % (item['name'], ', '.join(item['links'])) for item in tool_dict[section]])
        )
    return content


def get_tool_link(name, owner, revision, tool_shed_url):
    return '[%s](https://%s/view/%s/%s/%s)' % (
        revision, tool_shed_url, owner, name, revision
    )


def main(current_build_number, begin_build, end_build, report_file='report.md', date=''):
    table = []
    tools = []
    with open(log_file) as tsvfile:
        reader = csv.DictReader(tsvfile, dialect='excel-tab')
        for row in reader:
            table.append(row)

    if current_build_number:
        previous_jenkins_update_build_num = max(
            [int(y) for y in [row['Build Num.'] for row in table if row['Category'] == 'Update'] if int(y) < int(current_build_number)]
        )
        start_row = get_build_range(table, 'update', previous_jenkins_update_build_num)[1] + 1
        finish_row = get_build_range(table, 'update', current_build_number)[1]
    elif begin_build and end_build:
        begin_category, begin_build_number = begin_build.split('-')
        start_row = get_build_range(table, begin_category, begin_build_number)[0]
        end_category, end_build_number = end_build.split('-')
        finish_row = get_build_range(table, end_category, end_build_number)[1]

    for row in table[start_row:finish_row+1]:
        if row['Status'] == 'Installed' and row['Section Label'] != 'None':
            link = get_tool_link(row['Name'], row['Owner'], row['Installed Revision'], row['Tool Shed URL'])
            matching_tools = [tool for tool in tools if tool['owner'] == row['Owner'] and tool['name'] == row['Name']]
            if matching_tools:
                matching_tools[0]['links'].append(link)
            else:
                tools.append({
                    'name': row['Name'],
                    'owner': row['Owner'],
                    'links': [link],
                    'new': row['New Tool'] == 'True',
                    'label': row['Section Label']
                })

    if not tools:  # nothing to report
        sys.stderr.write('No tools installed this week.\n')
        return

    installed_tools = {}
    updated_tools = {}
    for tool in tools:
        label = tool.pop('label')
        if tool['new']:
            if label not in installed_tools.keys():
                installed_tools[label] = []
            installed_tools[label].append(tool)
        else:
            if label not in updated_tools.keys():
                updated_tools[label] = []
            updated_tools[label].append(tool)

    with open(report_file, 'w') as report:
        report.write(get_report_header(date))
        report.write(style)
        if installed_tools:
            report.write('\n### Tools installed\n\n')
            report.write(tool_table(installed_tools))
        if updated_tools:
            report.write('\n### Tools updated\n\n')
            report.write(tool_table(updated_tools))


if __name__ == "__main__":
    args = parser.parse_args()
    main(
        current_build_number=args.jenkins_build_number,
        begin_build=args.begin_build,
        end_build=args.end_build,
        report_file=args.outfile,
        date=args.date,
    )
