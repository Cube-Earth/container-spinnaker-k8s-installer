#!/bin/bash

set -o errexit
set -o nounset

function createRootCA
{
	[[ -f "$certs_dir/rootCA.crt" ]] && return 0
	if kubectl get secret "root-ca" -n kube-system > /dev/null 2>&1
	then
		echo "downloading root certificate ..."
		kubectl get secret "root-ca" -n kube-system -o jsonpath='{.data.tls\.key}' | base64 --decode > "$certs_dir/rootCA.key"
		kubectl get secret "root-ca" -n kube-system -o jsonpath='{.data.tls\.crt}' | base64 --decode > "$certs_dir/rootCA.crt"
	else
		echo "creating and uploading root certificate ..."
		openssl req -x509 -nodes -days 3650 -newkey rsa:4096 -sha256 -keyout "$certs_dir/rootCA.key" -out "$certs_dir/rootCA.crt" -subj "/CN=root ca/O=k8s"
		kubectl create secret tls "root-ca" --key "$certs_dir/rootCA.key" --cert "$certs_dir/rootCA.crt" -n kube-system
	fi
}


function createTillerCert
{
	kubectl create namespace tiller 2>/dev/null && err=$?

	[[ -f "$certs_dir/tiller.crt" ]] && return 0
	if kubectl get secret "tiller-tls" -n tiller > /dev/null 2>&1
	then
		echo "downloading tiller certificate ..."
		kubectl get secret "tiller-tls" -n tiller -o jsonpath='{.data.tls\.key}' | base64 --decode > "$certs_dir/tiller.key"
		kubectl get secret "tiller-tls" -n tiller -o jsonpath='{.data.tls\.crt}' | base64 --decode > "$certs_dir/tiller.crt"
	else
		createRootCA
		
		echo "creating and uploading tiller certificate ..."

		openssl genrsa -out "$certs_dir/tiller.key" 2048

		openssl req -new -sha256 \
    		-key "$certs_dir/tiller.key" \
    		-subj "/CN=tiller/O=k8s" \
    		-reqexts SAN \
    		-config <(cat /etc/ssl/openssl.cnf \
        		<(printf "\n[SAN]\nsubjectAltName=DNS:mydomain.com,DNS:www.mydomain.com")) \
		    -out "$certs_dir/tiller.csr"
		    
		openssl req -in "$certs_dir/tiller.csr" -noout -text
		
		openssl x509 -req -in "$certs_dir/tiller.csr" -CA "$certs_dir/rootCA.crt" -CAkey "$certs_dir/rootCA.key" -CAcreateserial -out "$certs_dir/tiller.crt" -days 500 -sha256
		
		openssl x509 -in "$certs_dir/tiller.crt" -text -noout
    
		kubectl create secret tls "tiller-tls" --key "$certs_dir/tiller.key" --cert "$certs_dir/tiller.crt" -n tiller
	fi
}


n=`kubectl get pods -n spinnaker 2>/dev/null | wc -l`
[[ "$n" -gt 0 ]] && echo "WARNING: Spinnaker already installed. skipping installation ..." && exit 0

export ACCOUNT='spinnaker'
hal config provider kubernetes account add "$ACCOUNT" \
    --provider-version v2 \
    --context $(kubectl config current-context)
    
hal config features edit --artifacts true
hal config deploy edit --type distributed --account-name "$ACCOUNT"

n=`kubectl get pods -n tiller 2>/dev/null | wc -l`

if [[ "$n" -eq 0 ]]
then
	certs_dir='/home/user/certs'
	mkdir -p "$certs_dir"
	
	createTillerCert

	cp ~/certs/rootCA.crt ~/.helm/ca.pem
	cp ~/certs/tiller.crt ~/.helm/cert.pem
	cp ~/certs/tiller.key ~/.helm/key.pem
	
	#kubectl delete deployment --namespace=tiller tiller-deploy
	echo "Installing tiller ..."
	kubectl apply -f ~/yaml/tiller.yaml
	helm init --history-max=100 --tiller-tls --tiller-tls-verify --tiller-tls-cert "$certs_dir/tiller.crt" --tiller-tls-key "$certs_dir/tiller.key" --tls-ca-cert "$certs_dir/rootCA.crt" --override 'spec.template.spec.containers[0].command'='{/tiller,--storage=secret}' --service-account=tiller 

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
	
	echo "Installing minio ..."	
	
	kubectl create namespace spinnaker 2>/dev/null && err=$?
	
	if [[ -z "${MINIO_ACCESS_KEY-}" ]] || [[ -z "${MINIO_SECRET_KEY-}" ]]
	then
		export MINIO_ACCESS_KEY=`openssl rand -hex 16`
		export MINIO_SECRET_KEY=`openssl rand -hex 32`
		echo -n "$MINIO_ACCESS_KEY\n$MINIO_SECRET_KEY" > "$certs_dir/minio.txt"
	fi

	helm install --tls --namespace spinnaker --name minio --set accessKey=$MINIO_ACCESS_KEY --set secretKey=$MINIO_SECRET_KEY stable/minio
	mkdir -p ~/.hal/default/profiles
	echo "spinnaker.s3.versioning: false" > front50-local.yml
	
	echo $MINIO_SECRET_KEY | \
    hal config storage s3 edit --endpoint http://minio:9000 \
         --access-key-id $MINIO_ACCESS_KEY \
         --secret-access-key
    hal config storage edit --type s3
    
    echo "Installing spinnaker ..."
    v=`hal -q version latest`
    hal config version edit --version "$v"
    
    hal deploy apply
    
    echo "Configuring spinnaker ..."
    
    ###TODO: Deploy Ingress for Spinnaker
    
    #hal config security ui edit --override-base-url "http://$SPIN_HOST:30900"
	#hal config security api edit --override-base-url "http://$SPIN_HOST:30808"
    
    #hal deploy apply
fi
