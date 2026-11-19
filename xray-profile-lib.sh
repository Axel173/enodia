#!/bin/sh
# The router owns the SOCKS listener, log and unsupported geo match entries.
xp_get() { jsonfilter -i "$1" -e "$2" 2>/dev/null; }
xp_read() { printf '%s\n' "$1" | jsonfilter -e "$2" 2>/dev/null || :; }

xp_scan() {
    _xps_program=$1; shift
    LC_ALL=C awk "$@" '
    { text=text $0 "\n" }
    function part(a,b) { return substr(text,start[a],finish[b]-start[a]+1) }
    function value_end(a, b) {
        if(closing[a]) return closing[a]
        b=a+1
        while(b<=n && level[b]==level[a] && token[b]!="," && token[b]!="}" && token[b]!="]") b++
        return b-1
    }
    function scan(    i,j,q,c,depth) {
        depth=0; n=0; others=""
        for(i=1;i<=length(text);i++) {
            c=substr(text,i,1)
            if(c ~ /[ \t\r\n]/) continue
            start[++n]=i; level[n]=depth
            if(c=="\"") {
                for(j=i+1;j<=length(text);j++) {
                    q=substr(text,j,1)
                    if(q=="\\") j++
                    else if(q=="\"") break
                }
                token[n]=substr(text,i,j-i+1); i=j
            } else {
                token[n]=c
                if(c=="{" || c=="[") open_at[++depth]=n
                if(c=="}" || c=="]") { closing[open_at[depth]]=n; depth-- }
            }
            finish[n]=i
        }
    }
    function key_at(i, k) {
        k=tolower(token[i])
        gsub(/ſ|\\u017[fF]/,"s",k)
        return k
    }
    '"$_xps_program"
}

# Fold only keys at the object boundary being read. Preserve the raw JSON
# value until its type is known (jsonfilter prints strings without quotes).
xp_object() {
    printf '%s\n' "$1" | xp_scan '
    END {
        scan()
        if(token[1]!="{") exit
        for(i=2;i<n;i=last+2) {
            last=value_end(i+2)
            key=key_at(i)
            fields[key]=((key=="\"address\"" || key=="\"endpoint\"") && token[i+2]!~/^"/ ? "null" : part(i+2,last))
        }
        sep="{"
        for(key in fields) { printf "%s%s:%s",sep,key,fields[key]; sep="," }
        if(sep=="{") printf "{"
        print "}"
    }'
}

# jsonfilter parses JSON first. The scanner copies whole values outside the
# router-owned boundary, including unknown provider extensions.
xp_sanitize() {   # <owned error path> [SOCKS port] [emit geo status] [test log level]; JSON on stdin
    xp_scan '
    function geo_ref(s) {
        sub(/^([[:space:]]|\\[trnf])+/, "", s)
        return tolower(s) ~ /^geo(site|ip):/
    }
    function geo_match(a,b,    i,last,s,keep,before,count,items) {
        before=geo
        if(token[a]=="[") {
            for(i=a+1;i<b;i=last+2) {
                last=value_end(i)
                s=part(i,last)
                if(substr(s,1,1)=="\"" && geo_ref(substr(s,2,length(s)-2))) geo++
                else {
                    if(keep!="") keep=keep ","
                    keep=keep s
                }
            }
            if(geo>before) return keep=="" ? "" : "[" keep "]"
        } else if(token[a]~/^"/) {
            # Go accepts the same list as a comma-separated JSON string.
            s=token[a]
            count=split(substr(s,2,length(s)-2),items,",")
            for(i=1;i<=count;i++) {
                if(geo_ref(items[i])) geo++
                else {
                    if(last++) keep=keep ","
                    keep=keep items[i]
                }
            }
            if(geo>before) return last ? "\"" keep "\"" : ""
        }
        return part(a,b)
    }
    function geo_rule(a,b,    i,last,key,s,keep,before,sourceip,domains,active,seen) {
        if(token[a]!="{") return part(a,b)
        before=geo
        for(i=a+1;i<b;i=last+2) {
            last=value_end(i+2)
            key=key_at(i)
            seen[key]=i
            if(key=="\"sourceip\"") sourceip=(part(i+2,last)!="null")
            if(key=="\"domains\"") domains=(part(i+2,last)!="null")
        }
        for(i=a+1;i<b;i=last+2) {
            last=value_end(i+2)
            key=key_at(i)
            if(key ~ /^"(domains?|ip|sourceip|source|localip)"$/) {
                # A non-null sourceIP suppresses source. Xray parses both
                # domain aliases, then domains replaces domain when present.
                active=(i==seen[key] && !(key=="\"source\"" && sourceip || key=="\"domain\"" && domains))
                s=geo_match(i+2,last)
                if(s=="") {
                    if(active) return ""
                    continue
                }
                s=part(i,i+1) s
            } else s=part(i,last)
            if(keep!="") keep=keep ","
            keep=keep s
        }
        return geo==before ? part(a,b) : "{" keep "}"
    }
    function routing(a,b,    i,last,r,end,s,keep,rules,before,old) {
        before=geo
        for(i=a+1;i<b;i=last+2) {
            last=value_end(i+2)
            s=part(i,last)
            if(key_at(i)=="\"rules\"" && token[i+2]=="[") {
                rules=""; old=geo
                for(r=i+3;r<last;r=end+2) {
                    end=value_end(r)
                    s=geo_rule(r,end)
                    if(s!="") {
                        if(rules!="") rules=rules ","
                        rules=rules s
                    }
                }
                s=(geo==old ? part(i,last) : part(i,i+1) "[" rules "]")
            }
            if(keep!="") keep=keep ","
            keep=keep s
        }
        return geo==before ? part(a,b) : "{" keep "}"
    }
    END {
        scan()
        if(token[1]!="{") exit 1
        for(k=2;k<n;k++) {
            if(level[k]!=1 || token[k+1]!=":") continue
            last=k+2
            while(last<n && !(level[last]==1 && (token[last]=="," || token[last]=="}"))) last++
            value=substr(text,start[k+2],finish[last-1]-start[k+2]+1)
            key=key_at(k)
            if(key=="\"log\"") {
                if(value=="null") {
                    for(name in fields) delete fields[name]
                    for(name in names) delete names[name]
                } else if(token[k+2]=="{") {
                    for(j=k+3;j<last;j++) {
                        if(level[j]!=2 || token[j+1]!=":") continue
                        end=j+2
                        while(end<last && !(level[end]==2 && (token[end]=="," || token[end]=="}"))) end++
                        key=key_at(j)
                        if(key!="\"access\"" && key!="\"error\"") {
                            val=substr(text,start[j+2],finish[end-1]-start[j+2]+1)
                            if(val!="null" || !(key in fields)) {
                                fields[key]=val
                                names[key]=token[j]
                            }
                        }
                        j=end
                    }
                }
            } else if(key=="\"routing\"" && token[k+2]=="{") {
                if(others!="") others=others ","
                others=others part(k,k+1) routing(k+2,last-1)
            } else if(port=="" || key!="\"inbounds\"") {
                if(others!="") others=others ","
                others=others substr(text,start[k],finish[last-1]-start[k]+1)
            } else if(!listener && token[k+2]=="[") {
                # Routing still needs the selected listener tag and sniffing.
                for(j=k+3;j<last;j++) {
                    if(level[j]!=3) continue
                    if(token[j]=="}") {
                        if(firsttag=="" && candidate!="\"\"") firsttag=candidate
                        if(proto=="\"socks\"" || proto=="\"mixed\"") {
                            if(!first_socks) { first_sniff=sniff; first_socks=1 }
                            if(candidate!="" && candidate!="\"\"") {
                                tag=candidate; sniffing=sniff; listener=1; break
                            }
                        }
                        candidate=""; proto=""; sniff=""
                    } else if(token[j+1]==":") {
                        key=tolower(token[j])
                        if(key=="\"tag\"" && token[j+2]~/^"/) candidate=token[j+2]
                        if(key=="\"protocol\"") proto=tolower(token[j+2])
                        if(key=="\"sniffing\"") sniff=(token[j+2]=="{" ? part(j+2,closing[j+2]) : "")
                    }
                }
            }
            k=last
        }
        key="\"loglevel\""
        severity=tolower(fields[key])
        if(severity!="\"error\"" && severity!="\"none\"") severity="\"warning\""
        if(test_level=="info") severity="\"info\""
        if(status!="") print (geo>0 ? 1 : 0)
        printf "{\"log\":{\"access\":\"none\",\"error\":\"%s\",\"loglevel\":%s",error,severity
        delete fields[key]
        # A stable rewrite avoids churning sync-mounted flash.
        while(1) {
            key=""
            for(name in fields) if(key=="" || name<key) key=name
            if(key=="") break
            printf ",%s:%s",names[key],fields[key]
            delete fields[key]
        }
        printf "}"
        if(port!="") {
            if(tag=="" || tag=="\"\"") tag=(firsttag!="" ? firsttag : "\"socks-in\"")
            printf ",\"inbounds\":[{\"tag\":%s,\"listen\":\"127.0.0.1\",\"port\":%s,\"protocol\":\"socks\",\"settings\":{\"udp\":true}",tag,port
            if(!listener) sniffing=first_sniff
            if(sniffing!="") printf ",\"sniffing\":%s",sniffing
            printf "}]"
        }
        if(others!="") printf ",%s",others
        print "}"
    }' -v error="$1" -v port="$2" -v status="${3:-}" -v test_level="${4:-}"
}

xp_runtime() {   # <file> [owned SOCKS port] [owned error log] [emit geo status] [test log level]
    _xpr_doc=$(xp_get "$1" '@') || return 1
    printf '%s\n' "$_xpr_doc" | xp_sanitize "${3:-/tmp/xray.log}" "${2:-}" "${4:-}" "${5:-}"
}

xp_reality_class() {
    case "$1" in
        ios|edge|qq|360|hellochrome_120|hellochrome_120_pq) printf 'incompatible' ;;
        random|randomized) printf 'intermittent' ;;
        *) return 1 ;;
    esac
}
XP_REALITY_TARGET=firefox
xp_reality_rev() {
    _xrr_sum=$(openssl dgst -sha256 < "$1" 2>/dev/null) || return 1
    printf '%s' "${_xrr_sum##* }"
}
xp_reality_failure() {   # <fp> <class> <revision> <this run's error log>
    [ -n "$2" ] && [ -n "$3" ] || return 0
    _xrr_ts='^[0-9/]+ [0-9:.]+'
    _xrr_cert="$_xrr_ts"' \[Error\] \[[0-9]+\] transport/internet/reality: REALITY: received real certificate \(potential MITM or redirection\)$'
    _xrr_retry="$_xrr_ts"' \[Info\] \[[0-9]+\] app/proxyman/outbound: .* > common/retry: \[transport/internet/reality: '
    _xrr_end='\] > common/retry: all retry attempts failed$'
    if ! grep -Eq -e "$_xrr_cert" -e "${_xrr_retry}REALITY: processed invalid connection$_xrr_end" "$4" 2>/dev/null; then
        [ "$1" = 360 ] && grep -Eq "${_xrr_retry}Current fingerprint 360Browser7\.5 does not support TLS 1\.3, REALITY handshake cannot establish\.$_xrr_end" "$4" 2>/dev/null || return 0
    fi
    printf ',"reality_fp":{"from":"%s","to":"%s","class":"%s","rev":"%s"}' "$1" "$XP_REALITY_TARGET" "$2" "$3"
}

# jsonfilter prints JSON null elements as no match. Split the validated JSON
# itself so such a row cannot hide later profiles or change their indices.
xp_profile_rows() {
    xp_get "$1" '@' | awk '
    /^[[:space:]]*\[/ {
        depth=0; start=0
        for(i=1;i<=length($0);i++) {
            c=substr($0,i,1)
            if(quoted) {
                if(c=="\\") i++
                else if(c=="\"") quoted=0
                continue
            }
            if(depth==1 && (c=="," || c=="]")) {
                if(start) print substr($0,start,i-start)
                start=0
            } else if(depth==1 && !start && c!~/[ \t\r\n]/) start=i
            if(c=="\"") quoted=1
            if(c=="[" || c=="{") depth++
            if(c=="]" || c=="}") depth--
        }
        next
    }
    {print}'
}

# The flat form wins over stale server arrays. WireGuard's address array
# belongs to its local interface; xp_object exposes only address strings.
xp_servers() {   # <case-folded outbound JSON>
    _xsv_settings=$(xp_object "$(xp_read "$1" '@.settings')")
    [ -n "$_xsv_settings" ] || return 0
    case "$(xp_read "$_xsv_settings" '@.address')" in
        ''|null)
            xp_read "$_xsv_settings" '@.vnext[*]'
            xp_read "$_xsv_settings" '@.servers[*]'
            xp_read "$_xsv_settings" '@.peers[*]' ;;
        *) printf '%s\n' "$_xsv_settings" ;;
    esac
    return 0
}

xp_server_endpoint() {
    _xse_host=$(xp_read "$1" '@.address'); _xse_port=$(xp_read "$1" '@.port')
    if [ -z "$_xse_host" ] || [ "$_xse_host" = null ]; then
        _xse_peer=$(xp_read "$1" '@.endpoint')
        case "$_xse_peer" in *:*) _xse_host=${_xse_peer%:*}; _xse_port=${_xse_peer##*:} ;; esac
    fi
    case "$_xse_host" in \[*\]) _xse_host=${_xse_host#[}; _xse_host=${_xse_host%]} ;; esac
    # Match Go TrimSpace, keeping internal whitespace for the hostname filter.
    case "$_xse_host" in *[!A-Za-z0-9._:-]*) _xse_host=$(printf '%s\n' "$_xse_host" | LC_ALL=C awk '
        { if(NR>1) s=s "\n"; s=s $0 }
        END {
            ws="([[:space:]]|\302[\205\240]|\341\232\200|\342\200[\200-\212\250\251\257]|\342\201\237|\343\200\200)+"
            sub("^" ws,"",s); sub(ws "$","",s); print s
        }') ;; esac
    case "$_xse_host" in ''|null|*[!A-Za-z0-9._:-]*) return 1 ;; esac
    case "$_xse_port" in *[!0-9]*) _xse_port='' ;; esac
    printf '%s\t%s\n' "$_xse_host" "$_xse_port"
}

# Only dial-capable protocol schemas have server settings. Helper and
# unknown outbounds are copied as-is and Xray alone validates the graph.
xp_dialer_types() { grep -Ei '^(vless|vmess|trojan|shadowsocks|http|socks|wireguard|hysteria|masque)$'; }

xp_outbound_endpoints() {
    _xoe_outbound=$(xp_object "$1")
    xp_read "$_xoe_outbound" '@.protocol' | xp_dialer_types >/dev/null || return 1
    _xoe_rows=$(xp_servers "$_xoe_outbound" | while IFS= read -r _xoe_server; do
        xp_server_endpoint "$(xp_object "$_xoe_server")"
    done)
    [ -n "$_xoe_rows" ] || return 1
    printf '%s\n' "$_xoe_rows"
    _xoe_stream=$(xp_object "$(xp_read "$_xoe_outbound" '@.streamsettings')")
    [ -n "$_xoe_stream" ] || return 0
    xp_server_endpoint "$_xoe_stream" || :
    _xoe_http=$(xp_read "$_xoe_stream" '@.xhttpsettings')
    [ -n "$_xoe_http" ] || _xoe_http=$(xp_read "$_xoe_stream" '@.splithttpsettings')
    [ -n "$_xoe_http" ] || return 0
    _xoe_http=$(xp_object "$_xoe_http")
    _xoe_extra=$(xp_object "$(xp_read "$_xoe_http" '@.extra')")
    _xoe_download=$(xp_read "$_xoe_extra" '@.downloadsettings')
    [ -n "$_xoe_download" ] || _xoe_download=$(xp_read "$_xoe_http" '@.downloadsettings')
    xp_server_endpoint "$(xp_object "$_xoe_download")" || :
}

xp_endpoints() {
    xp_read "$(xp_object "$(xp_get "$1" '@')")" '@.outbounds[*]' | while IFS= read -r _xep_outbound; do
        xp_outbound_endpoints "$_xep_outbound" || :
    done | sort -u
}
# Count raw outbounds separately from the endpoint set: distinct paths may
# dial the same host. Auxiliary outbounds without servers do not count.
xp_pool() {
    _xpl_doc=${2-$(xp_object "$(xp_get "$1" '@')")}
    _xpl_routing=$(xp_object "$(xp_read "$_xpl_doc" '@.routing')")
    [ -z "$(xp_read "$_xpl_routing" '@.balancers[0]')" ] || return 0
    [ "$(xp_read "$_xpl_doc" '@.outbounds[*]' | while IFS= read -r _xpl_ob; do
        xp_read "$(xp_object "$_xpl_ob")" '@.protocol'
    done | xp_dialer_types | wc -l)" -gt 1 ]
}

# Scalar metadata is for list/ping/link callers, never admission.
xp_quote() {
    printf '%s' "$1" | awk '
        BEGIN { printf "\""; for(i=1;i<32;i++) controls[sprintf("%c",i)]=sprintf("\\u%04x",i) }
        { if(NR>1) printf "\\n"; for(i=1;i<=length($0);i++) {
            c=substr($0,i,1)
            if(c=="\\") printf "\\\\"
            else if(c=="\"") printf "\\\""
            else if(c in controls) printf "%s",controls[c]
            else printf "%s",c
        } }
        END { printf "\"" }'
}
xp_canonical_ob() {   # <outbound JSON> [form]
    _xco_outbound=$(xp_object "$1")
    _xco_proto=$(xp_read "$_xco_outbound" '@.protocol' | tr 'A-Z' 'a-z')
    printf '%s\n' "$_xco_proto" | xp_dialer_types >/dev/null || return 1
    _xco_servers=$(xp_servers "$_xco_outbound")
    _xco_server=$(xp_object "$(printf '%s\n' "$_xco_servers" | head -n1)")
    _xco_endpoint=$(xp_server_endpoint "$_xco_server") || return 1
    _xco_tab=$(printf '\t')
    _xco_account=$(xp_object "$(xp_read "$_xco_server" '@.users[0]')")
    _xco_form_fields=''
    if [ "${2:-}" = form ]; then
        _xco_form_fields='method encryption alterid security'
        [ "$(printf '%s\n' "$_xco_servers" | wc -l)" -eq 1 ] || return 1
        _xco_port=${_xco_endpoint#*"$_xco_tab"}
        [ "${_xco_port:-0}" -ge 1 ] && [ "$_xco_port" -le 65535 ] || return 1
        case "$_xco_proto" in
            vless|vmess)
                [ -z "$(xp_read "$_xco_server" '@.users[1]')" ] || return 1
                [ -n "$(xp_read "${_xco_account:-$_xco_server}" '@.id')" ] || return 1 ;;
            trojan|shadowsocks)
                [ -n "$(xp_read "$_xco_server" '@.password')" ] || return 1
                [ "$_xco_proto" != shadowsocks ] || [ -n "$(xp_read "$_xco_server" '@.method')" ] || return 1 ;;
            *) return 1 ;;
        esac
    fi
    [ -n "$_xco_account" ] || _xco_account=$_xco_server
    printf '{"protocol":'; xp_quote "$_xco_proto"
    printf ',"tag":'; xp_quote "$(xp_read "$_xco_outbound" '@.tag')"
    printf ',"address":'; xp_quote "${_xco_endpoint%%"$_xco_tab"*}"
    printf ',"port":'; xp_quote "${_xco_endpoint#*"$_xco_tab"}"
    printf ',"account":{'
    _xco_sep=''
    for _xco_key in id password flow ${_xco_form_fields:-}; do
        printf '%s"%s":' "$_xco_sep" "$_xco_key"
        xp_quote "$(xp_read "$_xco_account" "@.$_xco_key")"
        _xco_sep=,
    done
    _xco_stream=$(xp_read "$_xco_outbound" '@.streamsettings')
    [ -n "$_xco_stream" ] || _xco_stream='{}'
    printf '},"streamSettings":%s}\n' "$_xco_stream"
}
xp_first() {
    _xpf_doc=${3-$(xp_object "$(xp_get "$1" '@')")}
    _xpf_i=0
    while _xpf_ob=$(xp_read "$_xpf_doc" "@.outbounds[$_xpf_i]") && [ -n "$_xpf_ob" ]; do
        if [ "${2:-}" = form ]; then
            if _xpf_member=$(xp_canonical_ob "$_xpf_ob" form); then
                printf '{"index":%s,%s\n' "$_xpf_i" "${_xpf_member#\{}"
                return 0
            fi
        elif xp_canonical_ob "$_xpf_ob"; then
            return 0
        fi
        _xpf_i=$((_xpf_i+1))
    done
    return 1
}
# Private editor/export metadata is served alongside the original file.
xp_view() {
    _xpv_file=$1
    _xpv_pool=false
    xp_pool "$_xpv_file" && _xpv_pool=true
    _xpv_member=''
    if [ "$_xpv_pool" = false ]; then _xpv_member=$(xp_first "$_xpv_file" form); fi
    _xpv_valid=false
    if [ -n "$_xpv_member" ] || [ -n "$(xp_endpoints "$_xpv_file")" ]; then _xpv_valid=true; fi
    printf '{"pool":%s,"valid":%s,"member":%s,"remark":' "$_xpv_pool" "$_xpv_valid" "${_xpv_member:-null}"
    xp_quote "$(xp_get "$_xpv_file" '@.remarks')"
    printf '}\n'
}
xp_field() { xp_first "$1" | jsonfilter -e "@.$2" 2>/dev/null; }
xp_reality_fp() {   # unambiguous REALITY stream, from the existing outbound reader
    _xrf_doc=$(xp_get "$1" '@') || return 1
    [ "$(printf '%s\n' "$_xrf_doc" | grep -oi '"realitysettings"[[:space:]]*:' | wc -l)" -eq 1 ] || return 1
    _xrf_doc=$(xp_object "$_xrf_doc")
    xp_pool "$1" "$_xrf_doc" && return 1
    _xrf_stream=$(xp_object "$(xp_read "$(xp_first "$1" '' "$_xrf_doc")" '@.streamSettings')")
    [ "$(xp_read "$_xrf_stream" '@.security' | tr 'A-Z' 'a-z')" = reality ] || return 1
    xp_read "$(xp_object "$(xp_read "$_xrf_stream" '@.realitysettings')")" '@.fingerprint'
}

# THE SERVER LIST'S ROWS (cgi-bin/list), CACHED BY CONTENT. Reading one profile costs ~0.3 s on the router (the JSON scanner runs
# several times per file): 91 profiles held `/cgi-bin/list` 22 s on AX3600 and 12 s on BE7000 (walk 19.11.2026) — every «Серверы»
# screen and every link to a server waited that long. A file's rows depend only on its bytes and on this library, so they are kept
# in RAM under the file's md5 and the library's md5: a file seen before costs no process, a new or edited one pays once. Display
# metadata only, never admission. The cache is rebuilt whole (`lbl_commit`); without label-lib or RAM the rows are still answered.
XP_META_CACHE=${XP_META_CACHE:-/tmp/enodia-xray-meta}
XP_LIB=${XP_LIB:-${ENODIA_DIR:+$ENODIA_DIR/xray-profile-lib.sh}}
# The version key is the code THIS process runs, hashed when it was sourced: an update replacing the file under a running list or
# warm-up made the old parser's rows carry the new key (review 3), and the new code then trusted them.
XP_LIB_MD5=
if [ -n "$XP_LIB" ] && [ -f "$XP_LIB" ]; then XP_LIB_MD5=$(md5sum < "$XP_LIB" 2>/dev/null | cut -c1-32); fi
# «md5⇥path» paired BY POSITION with the arguments: GNU md5sum escapes a backslash in a name (busybox does not), so the path is never
# read back from its output. Code 1 — the counts differ (a file vanished since the glob).
_xmr_pair() { { md5sum "$@" 2>/dev/null; echo --; printf '%s\n' "$@"; } | awk '
    $0 == "--" && !part { part = 1; next }
    !part { sub(/^\\/, ""); h[++n] = substr($0, 1, 32); next }
    { p[++m] = $0 }
    END { if (n != m) exit 1; for (i = 1; i <= n; i++) print h[i] "\t" p[i] }'; }
xp_meta_file() {   # <file> — `P` (a pool), `R⇥host` (a chain's relay, the address the router dials), `K⇥key⇥value`; 2 — unread
    # The reader itself failed (no jsonfilter, a fork refused under the boot's memory pressure, not JSON): rows read now would be
    # blank, and cached they would stay blank after recovery (review 2) — code 2, the caller answers without caching.
    jsonfilter -i "$1" -e '@' >/dev/null 2>&1 || return 2
    if xp_pool "$1"; then printf 'P\n'; fi
    if grep -q '"dialerProxy"' "$1" 2>/dev/null; then
        _xmf_rh=$(xp_members "$1" endpoints | head -n 1 | cut -f1 | tr -cd 'A-Za-z0-9.:-')
        [ -z "$_xmf_rh" ] || printf 'R\t%s\n' "$_xmf_rh"
    fi
    _xmf_m=$(xp_first "$1")
    [ -n "$_xmf_m" ] || return 0
    for _xmf_k in protocol address; do printf 'K\t%s\t%s\n' "$_xmf_k" "$(xp_read "$_xmf_m" "@.$_xmf_k")"; done
    printf 'K\tflow\t%s\n' "$(xp_read "$_xmf_m" '@.account.flow')"
    for _xmf_k in network security; do printf 'K\t%s\t%s\n' "$_xmf_k" "$(xp_read "$_xmf_m" "@.streamSettings.$_xmf_k")"; done
    for _xmf_k in serverName fingerprint; do
        _xmf_v=$(xp_read "$_xmf_m" "@.streamSettings.realitySettings.$_xmf_k")
        [ -n "$_xmf_v" ] || _xmf_v=$(xp_read "$_xmf_m" "@.streamSettings.tlsSettings.$_xmf_k")
        printf 'K\t%s\t%s\n' "$_xmf_k" "$_xmf_v"
    done
}
# Rows of xp_meta_file for each file as `TYPE⇥path[⇥…]`, in the order of the files. Cache: line 1 `v⇥<library md5>`, then
# `<file md5>⇥<row>` (`.` — a file without rows). A path is taken from the arguments, never parsed, so a space, a colon or a
# backslash in a drive's mount point survives.
xp_meta_rows() {   # <file>… (none — the cache goes too: it holds what the directory holds)
    [ $# -gt 0 ] || { rm -f "$XP_META_CACHE"; return 0; }
    _xmr_ver=${XP_LIB_MD5:-none}
    # A file that vanished since the glob (a subscription pruning its servers) shifts the count: the rest is hashed again without it,
    # rather than every profile read anew (review 3: one pruned file put a hot list of 90 back on the full read).
    if ! _xmr_sums=$(_xmr_pair "$@"); then
        _xmr_n=$#
        while [ "$_xmr_n" -gt 0 ]; do _xmr_p=$1; shift; [ ! -f "$_xmr_p" ] || set -- "$@" "$_xmr_p"; _xmr_n=$((_xmr_n-1)); done
        [ $# -gt 0 ] || return 0
        _xmr_sums=$(_xmr_pair "$@") || _xmr_sums=
    fi
    if [ -z "$_xmr_sums" ]; then
        for _xmr_p in "$@"; do
            xp_meta_file "$_xmr_p" | while IFS= read -r _xmr_r; do
                case "$_xmr_r" in *"	"*) printf '%s\t%s\t%s\n' "${_xmr_r%%	*}" "$_xmr_p" "${_xmr_r#*	}" ;; *) printf '%s\t%s\n' "$_xmr_r" "$_xmr_p" ;; esac
            done
        done
        return 0
    fi
    _xmr_old=$(cat "$XP_META_CACHE" 2>/dev/null)
    case "$_xmr_old" in "v	$_xmr_ver"|"v	$_xmr_ver
"*) ;; *) _xmr_old="v	$_xmr_ver" ;; esac
    _xmr_add=$(printf '%s\n--\n%s\n' "$_xmr_old" "$_xmr_sums" | awk '
        $0 == "--" { part++; next }
        part == 0 { have[substr($0, 1, 32)] = 1; next }
        $0 != "" { h = substr($0, 1, 32); if (!(h in have) && !(h in seen)) { seen[h] = 1; print h "\t" substr($0, 34) } }' |
        while IFS='	' read -r _xmr_h _xmr_p; do
            _xmr_rows=$(xp_meta_file "$_xmr_p"); _xmr_rc=$?
            # A FILE THAT CHANGED SINCE IT WAS HASHED (the editor saved it, a subscription replaced or removed it) has rows of
            # other bytes: cached under the old hash they would also become the rows of an unchanged byte-identical twin (review
            # 1). They answer this request only (`!`, never cached); the next request reads the file anew. So do rows of a read
            # that failed (code 2, review 2).
            if [ "$_xmr_rc" != 0 ] || [ "$(md5sum < "$_xmr_p" 2>/dev/null | cut -c1-32)" != "$_xmr_h" ]; then
                printf '%s\n' "$_xmr_rows" | while IFS= read -r _xmr_r; do
                    [ -n "$_xmr_r" ] || continue
                    case "$_xmr_r" in *"	"*) printf '!\t%s\t%s\t%s\n' "${_xmr_r%%	*}" "$_xmr_p" "${_xmr_r#*	}" ;; *) printf '!\t%s\t%s\n' "$_xmr_r" "$_xmr_p" ;; esac
                done
            elif [ -n "$_xmr_rows" ]; then printf '%s\n' "$_xmr_rows" | sed "s/^/$_xmr_h	/"; else printf '%s\t.\n' "$_xmr_h"; fi
        done)
    # Rows of files no longer here leave the cache with this rebuild: it holds what the directory holds, not every file ever seen.
    _xmr_new=$(printf '%s\n--\n%s\n--\n%s\n' "$_xmr_old" "$_xmr_add" "$_xmr_sums" | awk -v ver="$_xmr_ver" '
        $0 == "--" { part++; next }
        $0 == "" { next }
        part == 0 { if (substr($0, 1, 2) != "v\t") { r[++n] = $0 }; next }
        part == 1 { if (substr($0, 1, 2) != "!\t") r[++n] = $0; next }
        { live[substr($0, 1, 32)] = 1 }
        END { print "v\t" ver; for (i = 1; i <= n; i++) if (substr(r[i], 1, 32) in live) print r[i] }')
    if [ "$_xmr_new" != "$_xmr_old" ] && command -v lbl_commit >/dev/null 2>&1; then lbl_commit "$XP_META_CACHE" "$_xmr_new" || :; fi
    printf '%s\n--\n%s\n' "$_xmr_new" "$_xmr_sums" | awk '
        $0 == "--" { part++; next }
        $0 == "" { next }
        part == 0 { if (substr($0, 1, 2) == "v\t") next; h = substr($0, 1, 32); row[h, ++c[h]] = substr($0, 34); next }
        { h = substr($0, 1, 32); p = substr($0, 34)
          for (i = 1; i <= c[h]; i++) { x = row[h, i]; if (x == ".") continue
              t = index(x, "\t"); if (t) print substr(x, 1, t - 1) "\t" p substr(x, t); else print x "\t" p } }'
    printf '%s\n' "$_xmr_add" | sed -n 's/^!	//p'
}

# Check the exact sanitized file with the installed engine. Its failure
# output can echo provider secrets, so report a fixed reason to the caller.
xp_geo_notice() { printf '%s\n' 'правила провайдера по geosite/geoip не применяются — разделение делает роутер'; }
xp_asset_dir() { dirname "$1"; }
xp_prepare() {   # <source> <private .json destination> <pinned binary path>
    XP_REASON='невалидный JSON (проверьте скобки и запятые)'
    XP_GEO_REMOVED=0
    _xpp_doc=$(xp_runtime "$1" 10808 '' geo) || return 1
    _xpp_nl='
'
    (umask 077; printf '%s\n' "${_xpp_doc#*"$_xpp_nl"}" > "$2") || return 1
    XP_REASON='не найден адрес прокси-сервера'
    [ -n "$(xp_endpoints "$2")" ] || return 1
    XP_REASON='Xray отклонил конфиг (run -test)'
    if [ -x "$3" ]; then
        XRAY_LOCATION_ASSET="$(xp_asset_dir "$3")" "$3" run -test -c "$2" >/dev/null 2>&1 || return 1
    fi
    XP_GEO_REMOVED=${_xpp_doc%%"$_xpp_nl"*}
    XP_REASON=''
}
# One answer for pool endpoint consumers. "usable" is an offline admission
# hint, never a health verdict: a numeric or cached member merits a startup
# attempt even after another candidate proved DNS dead. "ips" trusts only
# seeds for THIS profile's hosts, not a previous carrier's leftover snippet.
xp_members() {   # <config> endpoints|hosts|usable|ips [seed file] [shared]
    case "$2" in
        endpoints) xp_endpoints "$1" ;;
        hosts) xp_endpoints "$1" | cut -f1 | sort -u ;;
        ips)
            xp_members "$1" hosts | while IFS= read -r _xpm_host; do
                seed_ipv4_rows "$_xpm_host" "${3:-}" "${4:-}"
            done | sort -u ;;
        usable)
            xp_members "$1" hosts | while IFS= read -r _xpm_host; do
                if printf '%s\n' "$_xpm_host" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
                    printf '%s\n' "$_xpm_host"
                else
                    case "$_xpm_host" in *:*) printf '%s\n' "$_xpm_host"; continue ;; esac
                    if command -v seed_cache_get >/dev/null 2>&1; then
                        _xpm_cached=$(seed_cache_get "$_xpm_host")
                        [ -z "$_xpm_cached" ] || printf '%s\n' "$_xpm_host"
                    fi
                fi
            done | sort -u ;;
        *) return 1 ;;
    esac
}
