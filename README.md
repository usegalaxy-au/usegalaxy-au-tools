## usegalaxy-au-tools
HELLO

This repository consists of .yml files or tools installed on Galaxy Australia and scripts for Travis CI and and Jenkins automated tool installation process.  The .yml files are maintained by the Jenkins process and should not be edited directly.

### Requesting a tool on Galaxy Australia

1. Make a fork of this repository.
2. On a branch, create one or more yaml files within the 'requests' directory in the following format:

```
tools:
  - name: <tool name>
    owner: <tool owner>
    tool_panel_section_label: <Tool section label existing on Galaxy Australia>
    tool_shed_url: # optional: omit this line to use default 'toolshed.g2.bx.psu.edu'
    revisions: # optional: omit this section to use default latest available revision
      - revision_hash_1
      - revision_hash_2
```

See the Galaxy Tool Shed https://toolshed.g2.bx.psu.edu/ for information about Galaxy tools.
There is also an [example yaml file](requests/template/example.yml) in this repository.

3. Open a pull request in this repository.
4. The pull request will be reviewed and merged by administrators.  Upon merging, the Jenkins process will install the tool or tools on Galaxy Australia staging and production servers.

![Automated process for installing tools on Galaxy Australia](/images/installation_process_flow_chart.png)

The log file [automated_tool_installation_log.tsv](automated_tool_installation_log.tsv) contains a record of tools installations.  Jenkins edits this file once the installation process is complete .
