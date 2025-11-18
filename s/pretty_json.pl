#!/home/y/bin/perl -w

print "var x = ";
while (<>) {
    s/","/",\n"/xg;              # replace ","
    s/",\s"/",\n"/xg;            # replace ", "
    s/:\[/:\[\n/xg;              # replace :[
    s/:\{"/:{\n"/xg;             # replace :{"
    s/\},\{/\},\n\{/xg;          # replace },{
    s/\},"/\},\n"/xg;            # replace },"
    s/,"/,\n"/xg;                # replace ,"
    s/\]\},/\]\n\},/xg;          # replace ]},
    s/\}\],/\n\}\n],/xg;         # replace }],
    s/\}\]/\n\}\n]/xg;           # replace }]
    s/\}\},/\}\n\},/xg;          # replace }},
    s/\}\}/\n\}\n}/xg;           # replace }}
    s/"\},/"\n},/xg;             # replace "},
    s/(false|true)\}/$1\n\}/xg;  # replace true}
    s/^\{/\{\n/x;                # replace leading {{
    s/^\[\{/\[\n\{/x;            # replace leading [{
    s/\}\]$/\}\n\]/x;            # replace trailing }]
    print;
}
