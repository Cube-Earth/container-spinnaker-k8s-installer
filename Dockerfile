FROM cubeearth/halyard



#USER user

ADD run.sh /usr/local/bin/
ADD tiller.yaml /home/user/yaml/

VOLUME /home/user/.kube
VOLUME /home/user/certs

#EXPOSE 8064

#ENTRYPOINT [ "/usr/local/bin/run.sh" ]

