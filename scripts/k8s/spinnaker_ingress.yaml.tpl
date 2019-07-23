---
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: spin-deck
  annotations:
    ingress.kubernetes.io/affinity: cookie
    ingress.kubernetes.io/ssl-redirect: "false"
spec:
  rules:
  - host: {{INGRESS_DNS}}
    http:
      paths:
      - path: /xxxxxx
        backend:
          serviceName: spin-deck
          servicePort: 9000

---
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: spinnaker-ingress
  annotations:
    ingress.kubernetes.io/ssl-redirect: "false"
    ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - host: {{INGRESS_DNS}}
    http:
      paths:
      - path: /gatexxxxx
        backend:
          serviceName: spin-gate
          servicePort: 8084
