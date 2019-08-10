FROM cubeearth/halyard

USER root

RUN apt-get update && apt-get -y upgrade && apt-get install -y wget vim jq && \
	sh -c "$(curl -sL https://github.com/Cube-Earth/Scripts/raw/master/shell/k8s/pod/prepare.sh)" - -c certs -c run && \
	mv /usr/local/bin/update-certs.sh /usr/local/bin/update-certs-local.sh

COPY scripts/ /usr/local/bin/

#VOLUME /home/user/.kube

ENTRYPOINT [ "/usr/local/bin/run.sh" ]
