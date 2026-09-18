function q(s, out,i,c) {
    out="\""
    for(i=1;i<=length(s);i++) {
        c=substr(s,i,1)
        if(c=="\\") out=out "\\\\"
        else if(c=="\"") out=out "\\\""
        else if(c=="\n") out=out "\\n"
        else if(c=="\r") out=out "\\r"
        else if(c=="\t") out=out "\\t"
        else if(c ~ /[[:cntrl:]]/) out=out "?"
        else out=out c
    }
    return out "\""
}
function timestamp(s, t) {t=s; gsub(/[-:]/," ",t); return mktime(t)}
function num(s) {return s ~ /^[0-9]+$/ ? s+0 : "null"}
/^@hosts$/ {mode="hosts";next}
/^@events$/ {mode="events";next}
/^@connections$/ {mode="connections";next}
mode=="hosts" {
    if($0 ~ /^#/ || $0=="") next
    split($0,h,"|"); name=h[1]
    if(name !~ /^[A-Za-z0-9_-]+$/) next
    order[++count]=name; kind[name]=h[2]; ip[name]=(h[5]!="" ? h[5] : h[4]); enabled[name]=(h[10]==1)
    next
}
{
    if($0 !~ /^[0-9][0-9][0-9][0-9]-/) next
    delete field
    for(i=4;i<=NF;i++) {p=index($i,"="); if(p) field[substr($i,1,p-1)]=substr($i,p+1)}
    name=field["host"]; if(!(name in kind)) next
    at=$1 " " $2; epoch=timestamp(at)
    if(mode=="connections") {
        if(at>=connectionAt[name] && ($3=="[PASS]" || $3=="[FAIL]")) {
            connectionAt[name]=at; connection[name]=($3=="[PASS]" ? "ok" : field["reason"])
        }
        next
    }
    action=field["action"]
    if(field["duration"] ~ /^[0-9]+$/) duration[name]=field["duration"]
    if(field["selected_ip"]!="" && kind[name]=="remote" && at>=connectionAt[name]) {
        connectionAt[name]=at; connection[name]="ok"
    }
    if((action=="skip" || action=="connect_failed" || field["reason"]=="missing_sshpass_or_password" || field["reason"]=="missing_key") && at>=connectionAt[name]) {
        connectionAt[name]=at; connection[name]=(field["reason"]!="" ? field["reason"] : "ssh_error")
    }
    if(action=="cpu") {
        cpu[name]=field["cpu"]; cpuAt[name]=at
        slot=++samples[name]; sample[name,slot]=num(field["cpu"])
    }
    if(action=="disk") {disk[name]=field["disk_write_mb"]; diskAt[name]=at}
    if(action=="start" || action=="finish" || action=="activation_failed") {lastAction[name]=action; lastAt[name]=at}
    if(running && epoch>=started) {
        if(field["offset_sec"]!="") {nextAt[name]=epoch+field["offset_sec"]; phase[name]="waiting"}
        if(action=="start") {phase[name]="active"; nextAt[name]=0}
        if(action=="finish") {phase[name]=(field["rc"]=="0" ? "finished" : "error"); nextAt[name]=0}
        if(action=="activation_failed" || action=="skip") {phase[name]="error"; nextAt[name]=0}
    }
    # Whitelist display fields instead of exposing raw logs or SSH output.
    if(action!="" || field["offset_sec"]!="") {
        event="{\"at\":" q(at) ",\"host\":" q(name) ",\"level\":" q($3) ",\"action\":" q(action!="" ? action : "schedule")
        event=event ",\"cpu\":" num(field["cpu"]) ",\"disk_mb\":" num(field["disk_write_mb"]) ",\"rc\":" num(field["rc"]) "}"
        events[++eventCount]=event
    }
}
END {
    printf "{\"generated_at\":%d,\"controller\":{\"running\":%s,\"pid\":%d,\"started_at\":%d},\"hosts\":[",now,running?"true":"false",pid,started
    for(k=1;k<=count;k++) {
        name=order[k]; if(k>1) printf ","
        state=(!running ? (enabled[name]?"stopped":"disabled") : (phase[name]!=""?phase[name]:(enabled[name]?"waiting":"disabled")))
        printf "{\"name\":%s,\"type\":%s,\"ip\":%s,\"enabled\":%s,\"phase\":%s,\"connection\":%s,\"connection_at\":%s,\"cpu\":%s,\"cpu_at\":%s,\"disk_mb\":%s,\"disk_at\":%s,\"last_action\":%s,\"last_at\":%s,\"next_at\":%d,\"duration_sec\":%s,\"cpu_history\":[",q(name),q(kind[name]),q(ip[name]),enabled[name]?"true":"false",q(state),q(connection[name]!=""?connection[name]:"unknown"),q(connectionAt[name]),num(cpu[name]),q(cpuAt[name]),num(disk[name]),q(diskAt[name]),q(lastAction[name]),q(lastAt[name]),nextAt[name],num(duration[name])
        first=samples[name]-59; if(first<1) first=1
        for(j=first;j<=samples[name];j++) {if(j>first) printf ","; printf "%s",sample[name,j]}
        printf "]}"
    }
    printf "],\"events\":["
    first=eventCount-49; if(first<1) first=1
    for(j=first;j<=eventCount;j++) {if(j>first) printf ","; printf "%s",events[j]}
    print "]}"
}
