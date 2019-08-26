#!/usr/bin/env perl
#

use warnings;
use strict;

foreach my $f (glob "*.yml"){
  print "$f\n";
  my $outfile = $f;
  $outfile =~ s/(.*).yml/$1_updated.yml/;
  my $outpath = "updated/$outfile";
  my $x = `python ~/bin/toolshed_repo_updater.py -i $f -o $outpath`;
  print $x;
}
