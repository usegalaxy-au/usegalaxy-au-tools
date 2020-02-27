import csv
import arrow
import sys
import argparse
from pytz import timezone

default_tool_shed = 'toolshed.g2.bx.psu.edu'
date_format = 'DD/MM/YY HH:mm:ss'
aest = timezone('Australia/Queensland')

log_file = 'automated_tool_installation_log.tsv'
max_previous_update_days = 10  # the number of days to look back in log for last week's update.
default_days = 7  # use this number or previous days if no other method is satisfied


"""
Generate a report of weekly installations and updates on Galaxy Australia
Because this script runs at the end of the update cron job and the length
of the job may vary, we need to include only installations completed between
now and the time that this script was run last week
"""

parser = argparse.ArgumentParser(description='Generate report from installation log')
parser.add_argument('-j', '--jenkins_build_number', help='Build Number of current job if running with Jenkins')
parser.add_argument('-o', '--outfile', help='Name of report file to write')
parser.add_argument('-b', '--begin_build', help='Jenkins build in log to use as first in report, i.e. install-7 or update-3')
parser.add_argument('-e', '--end_build', help='Jenkins build in log to use as last in report, i.e. install-10 or update-6.  Default is end of file')


"""
Rules:  If build number is specified we look for all lines of the log file since (and not including)
the previous jenkins update.  If the previous jenkins update is at least  max_previous_update_days
we use now - 7 days instead to avoid double counting if there has been a week with no updates.
"""


def get_report_header(date):
    return (
        '---\n'
        'site: freiburg\n'
        'title: \'Galaxy Australia tool updates %s\'\n'
        'tags: [tools]\n'
        'supporters:\n'
        '    - galaxytrainingnetwork\n'
        '    - galaxyproject\n'
        '    - galaxyaustralia\n'
        '    - melbinfo\n'
        '    - qcif\n'
        '---\n\n' % date
    )


def get_build_range(table, build_category, build_number):
    rows = [
        row_num for (row_num, row) in enumerate(table) if row['Category'] == build_category.title() and row['Build Num.'] == build_number
    ]
    return (rows[0], rows[-1])

#
# def get_previous_week_end(week_end):
#     try:
#         with open(dates_file) as dates:
#             lines = dates.readlines()
#             return(arrow.get(lines[-1].strip()))
#     except Exception:  # maybe the file does not exist or look like we expect
#         return week_end.shift(days=-7)
#
#
# def time_window_satisfied(time_str,  week_begin, week_end):
#     time = arrow.get(time_str, date_format)
#     if time < week_end and time > week_begin:
#         return True
#     return False
#
# def get_first_line


def get_row_datetime_aest(row):
    return arrow.get(row['Date (AEST)'], date_format).replace(tz=aest)


def main(current_build_number, begin_build, end_build, report_file):
    installed_tools = {}
    # week_end = arrow.now() if not end
    # week_begin = get_previous_week_end(week_end)
    now = arrow.now()
    today_date = now.astimezone(aest).strftime('%Y-%m-%d')
    print('today_date')

    table = []
    with open(log_file) as tsvfile:
        reader = csv.DictReader(tsvfile, dialect='excel-tab')
        for row in reader:
            table.append(row)  # TODO: is there a better way than putting this in memory?
    #
    # previous_jenkins_update_start = None
    # for i, row in enumerate(table):
    if current_build_number:
        previous_jenkins_update_build_num = max(
            [int(y) for y in [row['Build Num.'] for row in table if row['Category'] == 'Update'] if int(y) != int(current_build_number)]
        )
        #
        # previous_jenkins_update_last_row = max(
        #     [x for x, row in enumerate(table) if row['Category'] == 'Update' and int(row['Build Num.']) == previous_jenkins_update_build])
        # )
        #
        # previous_jenkins_build = [
        #     (row_num, row) for row in enumerate(table) if row['Category'] == update and row['Build Num.'] == previous_jenkins_update_build_num
        # ]
        previous_build_range = get_build_range(table, 'update', previous_jenkins_update_build_num)
        previous_start_dt = get_row_datetime_aest(previous_build_range[0])
        if now - previous_start_dt > max_previous_update_days:
            # Too long since last update.  Get figures from 1 week to avoid double counting
            # Let's have another unpleasant list comprehension...
            one_week_ago = now.replace(days=-7)
            [start_row] = [x for x in range(len(table)) if x > 0 and get_row_datetime_aest(table[x]) > one_week_ago and get_row_datetime_aest(table[x-1]) < one_week_ago]
        else:
            start_row = previous_build_range[1] + 1
        finish_row = len(table) - 1
    elif begin_build and end_build:
        begin_category, begin_build_number = begin_build.split('-')
        start_row = get_build_range(table, begin_category, begin_build_number)[0]
        end_category, end_build_number = end_build.split('-')
        finish_row = get_build_range(table, end_category, end_build_number)[1]

    for row in table[start_row:finish_row+1]:
        label = row['Section Label'].strip()
        if row['Status'] == 'Installed':
        # if row['Status'] == 'Installed' and time_window_satisfied(row['Date (UTC)'], week_begin, week_end):
            if not label == 'None':
                if label not in installed_tools.keys():
                    installed_tools[label] = []
                installed_tools[label].append(row)

    if not installed_tools.keys():  # nothing to report
        sys.stderr.write('No tools installed this week.\n')
        return

    with open(report_file, 'w') as report:
        report.write(get_report_header(today_date))
        report.write('The following tools have been updated on Galaxy Australia\n\n')
        for key in sorted(installed_tools.keys()):
            new_tools = [tool for tool in installed_tools[key] if tool['New Tool'] == 'True']
            updated_tools = [tool for tool in installed_tools[key] if tool['New Tool'] == 'False']
            report.write('### %s\n\n' % key)
            for item in new_tools:
                shed_url = item['Tool Shed URL'] or default_tool_shed
                link = 'https://%s/view/%s/%s/%s' % (shed_url.strip(), item['Owner'].strip(), item['Name'], item['Installed Revision'])
                report.write(' - %s was updated to [%s](%s)\n' % (item['Name'], item['Installed Revision'], link))
            for item in updated_tools:
                shed_url = item['Tool Shed URL'] or default_tool_shed
                link = 'https://%s/view/%s/%s/%s' % (shed_url.strip(), item['Owner'].strip(), item['Name'], item['Installed Revision'])
                report.write(' - %s was updated to [%s](%s)\n' % (item['Name'], item['Installed Revision'], link))
            report.write('\n')


if __name__ == "__main__":
    args = parser.parse_args()
    main(
        current_build_number=args.jenkins_build_number,
        begin_build=args.begin_build,
        end_build=args.end_build,
        report_file=args.outfile,
    )
