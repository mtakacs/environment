#!/usr/bin/perl -w

use JSON;

my $json = new JSON;
while (my $js = <>) {
  my $obj = $json->jsonToObj($js);
  print $json->objToJson($obj, { pretty => 1, indent => 2}), "\n";
}

