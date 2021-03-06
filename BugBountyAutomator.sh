#!/bin/bash
## Automated Bug Bounty recon script
## By Cas van Cooten

### CONFIG (NOTE! SECRETS INSIDE!)
toolsDir='/root/toolkit'
telegram_api_key='X'
telegram_chat_id='X'
### END CONFIG

baseDir=$(dirname "$(readlink -f "$0")")
lastNotified=0
thorough=true

function notify {
    if [ $(($(date +%s) - lastNotified)) -le 3 ]; then
        echo "[!] Notifying too quickly, sleeping to avoid skipped notifications..."
        sleep 3
    fi
    message=`echo -ne "*BugBountyAutomator [$DOMAIN]:* $1" | sed 's/[^a-zA-Z 0-9*_]/\\\\&/g'`
    curl -s -X POST https://api.telegram.org/bot$telegram_api_key/sendMessage -d chat_id="$telegram_chat_id" -d text="$message" -d parse_mode="MarkdownV2" &> /dev/null
    lastNotified=$(date +%s)
}

for arg in "$@"
do
    case $arg in
        -h|--help)
        echo "BugBountyHunter - Automated Bug Bounty reconnaisance script"
        echo " "
        echo "$0 [options]"
        echo " "
        echo "options:"
        echo "-h, --help                show brief help"
        echo "-q, --quick               perform quick recon only (default: false)"
        echo "-d, --domain <domain>     top domain to scan, can take multiple"
        echo " "
        echo "example:"
        echo "$0 --quick -d google.com -d uber.com"
        exit 0
        ;;
        -q|--quick)
        thorough=false
        shift
        ;;
        -d|--domain)
        domainargs+=("$2")
        shift
        shift
        ;;
    esac
done

if [ "${#domainargs[@]}" -ne 0 ]
then
    IFS=', ' read -r -a DOMAINS <<< "${domainargs[@]}"
else
    read -r -p "[?] What's the target domain(s)? E.g. \"domain.com,domain2.com\". DOMAIN: " domainsresponse
    IFS=', ' read -r -a DOMAINS <<< "$domainsresponse"  
fi

if command -v subjack &> /dev/null # Very crude dependency check :D
then
	echo "[*] DEPENDENCIES FOUND. NOT INSTALLING."
else
    echo "[*] INSTALLING DEPENDENCIES..."
    # Based on running 'hackersploit/bugbountytoolkit' docker image which has Amass/Nmap included. Adapt where required.
    apt update --assume-yes 
    apt install --assume-yes phantomjs
    apt install --assume-yes xvfb
    apt install --assume-yes dnsutils
    pip install webscreenshot
	
    echo "[*] Updating Golang.."
    curl "https://raw.githubusercontent.com/udhos/update-golang/master/update-golang.sh" | bash

    echo "[*] INSTALLING GO DEPENDENCIES (OUTPUT MAY FREEZE)..."
    go get -u github.com/lc/gau
    go get -u github.com/tomnomnom/gf
    go get -u github.com/jaeles-project/gospider
    go get -u github.com/projectdiscovery/httpx/cmd/httpx
    go get -u github.com/tomnomnom/qsreplace
    go get -u github.com/haccer/subjack

    echo "[*] INSTALLING GIT DEPENDENCIES..."
    ### Nuclei (Workaround -https://github.com/projectdiscovery/nuclei/issues/291)
    cd "$toolsDir" || { echo "Something went wrong"; exit 1; }
    git clone -q https://github.com/projectdiscovery/nuclei.git 
    cd nuclei/cmd/nuclei/ || { echo "Something went wrong"; exit 1; }
    go build
    mv nuclei /usr/local/bin/

    ### Nuclei templates
    cd "$toolsDir"'/nuclei' || { echo "Something went wrong"; exit 1; }
    git clone -q https://github.com/projectdiscovery/nuclei-templates.git

    ### Gf-Patterns
    cd "$toolsDir" || { echo "Something went wrong"; exit 1; }
    git clone -q https://github.com/1ndianl33t/Gf-Patterns
    mkdir ~/.gf
    cp "$toolsDir"/Gf-Patterns/*.json  ~/.gf

    cd "$baseDir" || { echo "Something went wrong"; exit 1; }
fi

echo "[*] STARTING RECON."
notify "Starting recon on *${#DOMAINS[@]}* subdomains."

for DOMAIN in "${DOMAINS[@]}"
do
    mkdir "$DOMAIN"
    cd "$DOMAIN" || { echo "Something went wrong"; exit 1; }

    echo "[*] RUNNING RECON ON $DOMAIN."
    notify "Starting recon on $DOMAIN. Enumerating subdomains with Amass..."

    echo "[*] RUNNING AMASS..."
    amass enum --passive -d "$DOMAIN" -o "domains-$DOMAIN.txt" 
    notify "Amass completed! Identified *$(wc -l < "domains-$DOMAIN.txt")* subdomains. Checking for live hosts with HTTPX..."

    echo "[*] RUNNING HTTPX..."
    httpx -silent -no-color -l "domains-$DOMAIN.txt" -title -content-length -web-server -status-code -ports 80,8080,443,8443 -threads 25 -o "httpx-$DOMAIN.txt"
    cut -d' ' -f1 < "httpx-$DOMAIN.txt" | sort -u > "livedomains-$DOMAIN.txt"
    notify "HTTPX completed. *$(wc -l < "livedomains-$DOMAIN.txt")* endpoints seem to be alive. Checking for hijackable subdomains with SubJack..."

    echo "[*] RUNNING SUBJACK..."
    subjack -w "domains-$DOMAIN.txt" -t 100 -o "subjack-$DOMAIN.txt" -a
    if [ -f "subjack-$DOMAIN.txt" ]; then
        echo "[+] HIJACKABLE SUBDOMAINS FOUND!"
        notify "SubJack completed. One or more hijackable subdomains found!"
        notify "Hijackable domains: $(cat "subjack-$DOMAIN.txt")"
        notify "Gathering live page screenshots with WebScreenshot..."
    else
        echo "[-] NO HIJACKABLE SUBDOMAINS FOUND."
        notify "No hijackable subdomains found. Gathering live page screenshots with WebScreenshot..."
    fi

    echo "[*] RUNNING WEBSCREENSHOT..."
    webscreenshot -i "livedomains-$DOMAIN.txt" -o webscreenshot --no-error-file
    notify "WebScreenshot completed! Took *$(find webscreenshot/* -maxdepth 0 | wc -l)* screenshots. Getting Wayback Machine path list with GAU..."

    echo "[*] RUNNING GAU..."
    gau -subs -providers wayback -o "gau-$DOMAIN.txt" "$DOMAIN"
    grep '?' < "gau-$DOMAIN.txt" | qsreplace -a > "WayBack-$DOMAIN.txt"
    rm "gau-$DOMAIN.txt"
    notify "GAU completed. Got *$(wc -l < "WayBack-$DOMAIN.txt")* paths."

    ######### OBSOLETE, REPLACED BY NUCLEI #########
    # echo "[*] SEARCHING FOR TELERIK ENDPOINTS..."
    # notify "Searching for potentially vulnerable Telerik endpoints..."
    # httpx -silent -l "domains-$DOMAIN.txt" -path /Telerik.Web.UI.WebResource.axd?type=rau -ports 80,8080,443,8443 -threads 25 -mc 200 -sr -srd telerik-vulnerable
    # grep -r -L -Z "RadAsyncUpload" telerik-vulnerable | xargs --null rm
    # if [ "$(find telerik-vulnerable/* -maxdepth 0 | wc -l)" -eq "0" ]; then
    #     echo "[-] NO TELERIK ENDPOINTS FOUND."
    #     notify "No Telerik endpoints found."
    # else
    #     echo "[+] TELERIK ENDPOINTS FOUND!"
    #     notify "*$(find telerik-vulnerable/* -maxdepth 0 | wc -l)* Telerik endpoints found. Manually inspect if vulnerable!"
    #     for file in telerik-vulnerable/*; do
    #         printf "\n\n########## %s ##########\n\n" "$file" >> potential-telerik.txt
    #         cat "$file" >> potential-telerik.txt
    #     done
    # fi
    # rm -rf telerik-vulnerable

    # echo "[*] SEARCHING FOR EXPOSED .GIT FOLDERS..."
    # notify "Searching for exposed .git folders..."
    # httpx -silent -l "domains-$DOMAIN.txt" -path /.git/config -ports 80,8080,443,8443 -threads 25 -mc 200 -sr -srd gitfolders
    # grep -r -L -Z "\[core\]" gitfolders | xargs --null rm
    # if [ "$(find gitfolders/* -maxdepth 0 | wc -l)" -eq "0" ]; then
    #     echo "[-] NO .GIT FOLDERS FOUND."
    #     notify "No .git folders found."
    # else
    #     echo "[+] .GIT FOLDERS FOUND!"
    #     notify "*$(find gitfolders/* -maxdepth 0 | wc -l)* .git folders found!"
    #     for file in gitfolders/*; do
    #         printf "\n\n########## %s ##########\n\n" "$file" >> gitfolders.txt
    #         cat "$file" >> gitfolders.txt
    #     done
    # fi
    # rm -rf gitfolders
    ################################################

    if [ "$thorough" = true ] ; then
        echo "[*] RUNNING NUCLEI..."
        notify "Detecting known vulnerabilities with Nuclei..."
        nuclei -c 75 -l "livedomains-$DOMAIN.txt" -t "$toolsDir"'/nuclei/nuclei-templates/' -severity low,medium,high -o "nuclei-$DOMAIN.txt"
        notify "Nuclei completed. Found *$(wc -l < "nuclei-$DOMAIN.txt")* (potential) issues. Spidering paths with GoSpider..."

        echo "**] RUNNING GOSPIDER..."
        gospider -S "livedomains-$DOMAIN.txt" -o GoSpider -t 2 -c 5 -d 3 --blacklist jpg,jpeg,gif,css,tif,tiff,png,ttf,woff,woff2,ico,svg
        cat GoSpider/* | grep -o -E "(([a-zA-Z][a-zA-Z0-9+-.]*\:\/\/)|mailto|data\:)([a-zA-Z0-9\.\&\/\?\:@\+-\_=#%;,])*" | sort -u | qsreplace -a | grep "$DOMAIN" > "GoSpider-$DOMAIN.txt"
        rm -rf GoSpider
        notify "GoSpider completed. Crawled *$(wc -l < "GoSpider-$DOMAIN.txt")* endpoints. Identifying interesting parameterized endpoints (from WaybackMachine and GoSpider) with GF..."

        # Merge GAU and GoSpider files into one big list of (hopefully) interesting paths
        cat "WayBack-$DOMAIN.txt" "GoSpider-$DOMAIN.txt" | sort -u | qsreplace -a > "paths-$DOMAIN.txt"
        rm "WayBack-$DOMAIN.txt" "GoSpider-$DOMAIN.txt"

        ######### OBSOLETE, REPLACED BY GF / MANUAL #########
        # echo "[**] SEARCHING FOR POSSIBLE SQL INJECTIONS..."
        # notify "(THOROUGH) Searching for possible SQL injections..."
        # grep "=" "paths-$DOMAIN.txt" | sed '/^.\{255\}./d' | qsreplace "' OR '1" | httpx -silent -threads 25 -sr -srd sqli-vulnerable
        # grep -r -L -Z "syntax error\|mysql\|sql" sqli-vulnerable | xargs --null rm
        # if [ "$(find sqli-vulnerable/* -maxdepth 0 | wc -l)" -eq "0" ]; then
        #     notify "No possible SQL injections found."
        # else
        #     notify "Identified *$(find sqli-vulnerable/* -maxdepth 0 | wc -l)* endpoints potentially vulnerable to SQL injection!"
        #     for file in sqli-vulnerable/*; do
        #         printf "\n\n########## %s ##########\n\n" "$file" >> potential-sqli.txt
        #         cat "$file" >> potential-sqli.txt
        #     done
        # fi
        # rm -rf sqli-vulnerable
        #####################################################

        echo "[*] GETTING INTERESTING PARAMETERS WITH GF..."
        mkdir "check-manually"
        gf ssrf < "paths-$DOMAIN.txt" > "check-manually/server-side-request-forgery.txt"
        gf xss < "paths-$DOMAIN.txt" > "check-manually/cross-site-scripting.txt"
        gf redirect < "paths-$DOMAIN.txt" > "check-manually/open-redirect.txt"
        gf rce < "paths-$DOMAIN.txt" > "check-manually/rce.txt"
        gf idor < "paths-$DOMAIN.txt" > "check-manually/insecure-direct-object-reference.txt"
        gf sqli < "paths-$DOMAIN.txt" > "check-manually/sql-injection.txt"
        gf lfi < "paths-$DOMAIN.txt" > "check-manually/local-file-inclusion.txt"
        gf ssti < "paths-$DOMAIN.txt" > "check-manually/server-side-template-injection.txt"
        gf debug_logic < "paths-$DOMAIN.txt" > "check-manually/debug-logic.txt"
        notify "GF done! Identified *$(cat check-manually/* | wc -l)* interesting parameter endpoints to check. Resolving hostnames to IP addresses..."

        echo "[*] Resolving IP addresses from hosts..."
        while read -r hostname; do
            dig "$hostname" +short >> "dig.txt"
        done < "domains-$DOMAIN.txt"
        grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' "dig.txt" | sort -u > "ip-addresses-$DOMAIN.txt" && rm "dig.txt"
        notify "Resolving done! Starting Nmap for *$(wc -l < "ip-addresses-$DOMAIN.txt")* IP addresses..."

        echo "[*] RUNNING NMAP (TOP 1000 TCP)..."
        mkdir nmap
        nmap -T4 --open --source-port 53 --max-retries 3 --host-timeout 15m -iL "ip-addresses-$DOMAIN.txt" -oA nmap/nmap-tcp
        grep Port < nmap/nmap-tcp.gnmap | cut -d' ' -f2 | sort -u > nmap/tcpips.txt
        notify "Nmap TCP done! Identified *$(grep -c "Port" < "nmap/nmap-tcp.gnmap")* IPs with ports open. Starting Nmap UDP/SNMP scan for *$(wc -l < "nmap/tcpips.txt")* IP addresses..."   

        echo "[*] RUNNING NMAP (SNMP UDP)..."
        nmap -T4 -sU -sV -p 161 --open --source-port 53 -iL nmap/tcpips.txt -oA nmap/nmap-161udp
        rm nmap/tcpips.txt
        notify "Nmap TCP done! Identified *$(grep "Port" < "nmap/nmap-161udp.gnmap" | grep -cv "filtered")* IPS with SNMP port open." 
    fi

    cd ..
    echo "[+] DONE SCANNING $DOMAIN."
    notify "Recon on $DOMAIN finished."

done

echo "[+] DONE! :D"
notify "Recon finished! Go hack em!"
