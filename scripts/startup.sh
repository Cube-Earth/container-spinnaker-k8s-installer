#!/bin/lsh

PROVIDER=k8s

NODE_SELECTOR_1="beta.kubernetes.io/os: linux"
NODE_SELECTOR_2="beta.kubernetes.io/arch: amd64"

while getopts "p:" opt; do
    case "${opt}" in
        p)
        	PROVIDER=$OPTARG
            ;;
            
		\?)
      		echo "Invalid option: -$OPTARG" >&2
      		exit 1
      		;;
          esac
done
shift $((OPTIND-1))


#n=$(kubectl get pods -l app.kubernetes.io/part-of=spinnaker -ojson | jq '.items | length')
#[[ "$n" -gt 0 ]] && echo "WARNING: Spinnaker already installed. skipping installation ..." && exit 0

$DOWNLOAD https://raw.githubusercontent.com/Cube-Earth/Scripts/master/shell/k8s/pod/createKubeConfig.sh > /usr/local/bin/createKubeConfig.sh
chmod +x /usr/local/bin/createKubeConfig.sh
mkdir -p /usr/local/bin/awk
$DOWNLOAD https://raw.githubusercontent.com/Cube-Earth/Scripts/master/awk/replace_env.awk > /usr/local/bin/awk/replace_env.awk


#########################################
### Labeling nodes                    ###
#########################################

echo
echo '#########################################'
echo '### Labeling nodes                    ###'
echo '#########################################'
echo

IFS=$'\n'
for i in $(kubectl get node -ojson | jq -r '.items[] | select(.kind=="Node") | [(.metadata.name, .status.nodeInfo.operatingSystem, .status.nodeInfo.architecture, .metadata.labels."beta.kubernetes.io/os")] | @tsv')
do
	IFS=$'\t' read -r node os arch label <<< $i
	echo "# " + $node - $os - $arch - $label
	
	if [[ "$label" = "null" ]]
	then
		echo "labeling node $node ..."
		kubectl label --overwrite node "$node" "beta.kubernetes.io/os=$os" "beta.kubernetes.io/arch=$arch"
	fi
done
IFS=' '

#########################################
### Installing certificate server     ###
#########################################

echo
echo '#########################################'
echo '### Installing certificate server     ###'
echo '#########################################'
echo

n=$(kubectl get pods -l app=pod-cert-server -ojson | jq '.items | length')
if [[ "$n" -eq 0 ]]
then
	kubectl apply -f <(curl -sL https://github.com/Cube-Earth/container-k8s-cert-server/raw/master/k8s/pod-cert-server.yaml.tpl | awk -v ns=$POD_NAMESPACE '{ gsub(/\{\{ *namespace *\}\}/, ns); print }') 

	n=30
	$DOWNLOAD http://pod-cert-server/hello > /dev/null && rc=0 || rc=$?
	while [[ "$rc" -ne 0 ]]
	do
		n=$((n-1))
		[[ "$n" -eq 0 ]] && echo "ERROR: pod cert server did not successfully start." && exit 1
		sleep 1
		$DOWNLOAD http://pod-cert-server/hello > /dev/null && rc=0 || rc=$?
	done

fi

update-certs.sh
[[ ! -f /certs/tiller-default.cer ]] && echo "ERROR: pod cert server not started successfully!" && exit 1


#########################################
### Installing haproxy                ###
#########################################

n=$(kubectl get pods -l run=haproxy-ingress -A -ojson | jq '.items | length')
if [[ "$n" -eq 255 ]]
then
	echo
	echo '#########################################'
	echo '### Installing haproxy                ###'
	echo '#########################################'
	echo

	$DOWNLOAD https://raw.githubusercontent.com/Cube-Earth/Scripts/master/awk/ingress_add_port.awk > /tmp/ingress_add_port.awk
	$DOWNLOAD https://raw.githubusercontent.com/Cube-Earth/Scripts/master/k8s/haproxy.yaml | \
		awk -v protocol=spin-deck-http -v port=9000 -v target="$POD_NAMESPACE/spin-deck:9000" -f /tmp/ingress_add_port.awk | \
		awk -v protocol=spin-gate-http -v port=8084 -v target="$POD_NAMESPACE/spin-gate:8084" -f /tmp/ingress_add_port.awk > /tmp/haproxy.yaml

	kubectl apply -f /tmp/haproxy.yaml
fi

#########################################
### Installing tiller                 ###
#########################################

echo
echo '#########################################'
echo '### Installing tiller                 ###'
echo '#########################################'
echo

if [[ ! -f ~/.helm/key.pem ]]
then
	mkdir -p ~/.helm
	ln -s /certs/root_ca.cer ~/.helm/ca.pem
	ln -s /certs/tiller-default.cer ~/.helm/cert.pem
	ln -s /certs/tiller-default.key ~/.helm/key.pem
fi

export TILLER_NAMESPACE=$POD_NAMESPACE
n=$(kubectl get pod -l name=tiller -ojson | jq '.items | length')
if [[ "$n" -eq 0 ]]
then
	
	#kubectl delete deployment --namespace=$POD_NAMESPACE tiller-deploy
#	kubectl apply -f /usr/local/bin/k8s/tiller.yaml
	helm init --history-max=100 --tiller-tls --tiller-tls-verify --tiller-tls-cert /certs/tiller-default.cer --tiller-tls-key /certs/tiller-default.key --tls-ca-cert /certs/root-ca.cer --node-selectors "beta.kubernetes.io/os"="linux","beta.kubernetes.io/arch"="amd64" --override 'spec.template.spec.containers[0].command'='{/tiller,--storage=secret}' --service-account=pipeline

	n=72  # 72 * 5sec = 6min
	while ! helm list --tls > /dev/null 2>&1
	do
		n=$((n-1))
		[[ $n -lt 0 ]] && echo "ERROR: Installation of tiller failed!" && ( helm list --tls ; exit 1 )
		sleep 5
		echo -n "."
	done
	echo
	helm version --tls
fi


#########################################
### Installing minio                  ###
#########################################

if [[ "$PROVIDER" = "k8s" ]]
then

	echo
	echo '#########################################'
	echo '### Installing minio                  ###'
	echo '#########################################'
	echo

	export MINIO_ACCESS_KEY=$(curl -sL https://pod-cert-server/pwd/minio-access-key)
	export MINIO_SECRET_KEY=$(curl -sL https://pod-cert-server/pwd/minio-secret-key)

	n=$(kubectl get pod -l app=minio -ojson | jq '.items | length')
	if [[ "$n" -eq 0 ]]
	then
		
		kubectl apply -f /usr/local/bin/k8s/minio_pvc.yaml
		helm install --tls --namespace $POD_NAMESPACE --name minio --set nodeSelector.beta\\.kubernetes\\.io/os=linux --set nodeSelector.beta\\.kubernetes\\.io/arch=amd64 --set accessKey=$MINIO_ACCESS_KEY --set secretKey=$MINIO_SECRET_KEY --set persistence.existingClaim="minio-pvc" stable/minio

		# helm delete minio --purge --tls
	fi
fi


#########################################
### Installing ldap server            ###
#########################################

n=$(kubectl get pod -l app=ldap-server -ojson | jq '.items | length')
if [[ "$n" -eq 0 ]]
then
	echo
	echo '#########################################'
	echo '### Installing ldap server            ###'
	echo '#########################################'
	echo

	kubectl apply -f https://raw.githubusercontent.com/Cube-Earth/container-ldap-server/master/k8s/ldap-server.yaml
fi

#########################################
### Installing spinnaker              ###
#########################################

n=$(kubectl get pods -l app.kubernetes.io/part-of=spinnaker -ojson | jq '.items | length')
n=0
if [[ "$n" -eq 0 ]]
then

	echo
	echo '#########################################'
	echo '### Installing spinnaker              ###'
	echo '#########################################'
	echo

	#update-halyard

    	mkdir -p /home/user/.hal/default/service-settings
    	cat << EOF > /home/user/.hal/default/service-settings/gate.yml
kubernetes:
  volumes:
  - id: internal-trust-store
    mountPath: /etc/ssl/certs/java
    type: secret
  nodeSelector:
    $NODE_SELECTOR_1
    $NODE_SELECTOR_2
EOF

    	for i in clouddriver deck echo fiat front50 igor orca rosco redis
    	do
      		cat << EOF > /home/user/.hal/default/service-settings/$i.yml
kubernetes:
  nodeSelector:
    $NODE_SELECTOR_1
    $NODE_SELECTOR_2
EOF
    	done

	export ACCOUNT='spinnaker'
	
	case "$PROVIDER" in
		k8s)
			hal config provider aws disable
			hal config provider azure disable
			hal config provider kubernetes enable

			[[ ! -f ~/.kube/config ]] && createKubeConfig.sh -a pipeline -k		
		
                        [[ ! -f /tmp/k8s_acc_added.state ]] && hal config provider kubernetes account add "$ACCOUNT" --provider-version v2 --kubeconfig-file $HOME/.kube/config && touch /tmp/k8s_acc_added.state
			#    --context $(kubectl config current-context)
    
			mkdir -p /home/user/.hal/default/profiles
			echo "spinnaker.s3.versioning: false" > /home/user/.hal/default/profiles/front50-local.yml

			echo $MINIO_SECRET_KEY | \
    			hal config storage s3 edit --endpoint http://minio:9000 \
         		--access-key-id $MINIO_ACCESS_KEY \
         		--secret-access-key \
         		--region eu-west-1 \
         		--path-style-access true
    		hal config storage edit --type s3
			;;
			
		*)
			echo "ERROR: unknown provider '$PROVIDER'!"
			exit 1
			;;
	esac
	
	hal config features edit --artifacts true
	hal config deploy edit --type distributed --account-name "$ACCOUNT"

    v=`hal -q version latest`
    hal config version edit --version "$v"
    hal config deploy edit --location $POD_NAMESPACE

    curl -Ls https://pod-cert-server/pwd/ldap-root | hal config security authn ldap edit --manager-dn "cn=Manager,dc=k8s" --manager-password --user-search-base "ou=users,dc=k8s" --user-search-filter "(&(uid={0})(memberof=cn=admin,ou=groups,dc=k8s))" --url=ldaps://ldap:636
    # ldapsearch -H ldaps://ldap:636 -D "cn=Manager,dc=k8s" -b ou=users,dc=k8s -w <pwd> "(&(uid=admin)(memberof=cn=admin,ou=groups,dc=k8s))"
    hal config security authn ldap enable

    cp /etc/ssl/certs/java/cacerts /certs/cacerts
    cp /certs/root-ca.cer /certs/k8s-root-ca.cer
    keytool -import -trustcacerts -alias k8s-root-ca -keystore /certs/cacerts -file /certs/k8s-root-ca.cer -storepass changeit -noprompt
    #kubectl create secret generic internal-trust-store --from-file /certs/cacerts

    #hal config security authn x509 enable

    cd /tmp
    [[ -f /certs/gate.jks ]] && rm /certs/gate.jks
    openssl pkcs12 -export -clcerts -in /certs/spinnaker.cer -inkey /certs/spinnaker.key -out /certs/spinnaker.p12 -name spinnaker -password pass:secret
    openssl pkcs12 -export -clcerts -in /certs/gate.cer -inkey /certs/gate.key -out /certs/gate.p12 -name gate -password pass:secret
    keytool -importkeystore \
       -srckeystore /certs/gate.p12 -srcstoretype pkcs12 -srcalias gate -srcstorepass secret \
       -destkeystore /certs/gate.jks -destalias gate -deststoretype pkcs12 -deststorepass secret -destkeypass secret    
    keytool -trustcacerts -keystore /certs/gate.jks -importcert -alias ca -file /certs/root-ca.cer -storepass secret -noprompt
    keytool -list -keystore /certs/gate.jks -storepass secret

    echo "secret" | hal config security api ssl edit --key-alias gate --keystore /certs/gate.jks --keystore-type jks  --keystore-password   
    echo "secret" | hal config security api ssl edit --truststore /certs/gate.jks --truststore-password --truststore-type jks

    hal config security api ssl enable

    echo "" | hal config security ui ssl edit \
       --ssl-certificate-file /certs/deck.cer --ssl-certificate-key-file /certs/deck.key --ssl-certificate-passphrase

    hal config security ui ssl enable

    cat /home/user/.hal/config | awk -v f=/usr/local/bin/awk/customSizing.yml -f /usr/local/bin/awk/add_customSizing.awk | tee /home/user/.hal/config > /dev/null
	
	hal config security ui edit --override-base-url "https://$INGRESS_DNS:9000"
	hal config security api edit --override-base-url "https://$INGRESS_DNS:8084"

    hal deploy apply
fi


#########################################
### root-ca.cer                       ###
#########################################

echo
echo '#########################################'
echo '### root-ca.cer                       ###'
echo '#########################################'
echo
echo "Please import following root ca into your browser certificate store!"
echo

kubectl get secret managed-tls--root-ca -n kube-system -o jsonpath='{.data.tls\.crt}' | base64 -d


#########################################
### LDAP user 'admin'                 ###
#########################################

echo
echo '#########################################'
echo '### LDAP user 'admin'                 ###'
echo '#########################################'
echo
echo "Please use for logging into spinnaker the user 'admin' with following command to obtain the password:"
echo
echo "kubectl get secret managed-pwd-ldap-server---ldap-admin -n pipeline -o jsonpath='{.data.pwd}' | base64 -d"
echo
