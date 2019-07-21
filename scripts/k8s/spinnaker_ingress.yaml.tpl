---
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: spinnaker-ingress
  annotations:
    ingress.kubernetes.io/affinity: cookie
    ingress.kubernetes.io/ssl-redirect: "false"
spec:
  rules:
  - host: {{INGRESS_DNS}}
    http:
      paths:
      - path: /spinnaker/ui
        backend:
          serviceName: spin-deck
          servicePort: 9000
      - path: /spinnaker/gate
        backend:
          serviceName: spin-gate
          servicePort: 8084
