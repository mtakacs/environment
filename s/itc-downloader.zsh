#!/usr/bin/env zsh

##
## Download ITC premium videos from youTube for offline viewing
## use JWZ's youtubedown.pl to facilitate downloading.
##

## keep a list of the youtube videos on a google sheet so I can track
## @see https://docs.google.com/spreadsheets/d/1zJ-G5AKNBKcvjoQyUzQQJTnB29SqBzqc2OG4XJmvRqo/edit#gid=0
## Paste the two columns 'Date' and 'url'  into the TSV file

INPUT=itc.tsv
OLDIFS=$IFS
IFS='	'

[ ! -f $INPUT ] && { echo "$INPUT file not found"; exit 99; }

while read pubdate url
do
	echo "Date : $pubdate"
	echo "url : $url"
  ~/s/youtubedown.pl --prefix $pubdate --suffix "$url"
done < $INPUT
IFS=$OLDIFS
