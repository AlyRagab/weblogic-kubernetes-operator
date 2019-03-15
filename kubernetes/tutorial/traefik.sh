#!/bin/bash
# Copyright 2019, Oracle Corporation and/or its affiliates.  All rights reserved.
# Licensed under the Universal Permissive License v 1.0 as shown at http://oss.oracle.com/licenses/upl.

set -u

source waitUntil.sh

function createCon() {
  echo "install Treafik controller to namespace traefik"
  helm install stable/traefik \
    --name traefik-controller \
    --namespace traefik \
    --values $WLS_OPT_ROOT/kubernetes/samples/charts/traefik/values.yaml  \
    --set "kubernetes.namespaces={traefik,default,test1}" \
    --wait
}

function delCon() {
  echo "delete Traefik controller"
  helm delete --purge traefik-controller
  kubectl delete namespace traefik
  waitUntilNSTerm traefik
}

function createIng() {
  echo "install Ingress for domains"
  helm install $WLS_OPT_ROOT/kubernetes/samples/charts/ingress-per-domain \
    --name domain1-ing-t \
    --namespace default \
    --set wlsDomain.domainUID=domain1 \
    --set traefik.hostname=domain1.org

  helm install $WLS_OPT_ROOT/kubernetes/samples/charts/ingress-per-domain \
    --name domain2-ing-t \
    --namespace test1 \
    --set wlsDomain.domainUID=domain2 \
    --set traefik.hostname=domain2.org

  helm install $WLS_OPT_ROOT/kubernetes/samples/charts/ingress-per-domain \
    --name domain3-ing-t \
    --namespace test1 \
    --set wlsDomain.domainUID=domain3 \
    --set traefik.hostname=domain3.org

  waitUntilHTTPReady Domain1
  waitUntilHTTPReady Domain2
  waitUntilHTTPReady Domain3
}

function waitUntilHTTPReady() {
  expected_out=200
  okMsg="load balancing traffic to $1 is ready"
  failMsg="fail to load balancing traffic to $1 "

  waitUntil "checkHTTP${1}Cmd" "$expected_out" "$okMsg" "$failMsg"
}

function checkHTTPDomain1Cmd() {
  curl -s -o /dev/null -w "%{http_code}"  -H 'host: domain1.org' http://$HOSTNAME:30305/weblogic/
}

function checkHTTPDomain2Cmd() {
  curl -s -o /dev/null -w "%{http_code}"  -H 'host: domain2.org' http://$HOSTNAME:30305/weblogic/
}

function checkHTTPDomain3Cmd() {
  curl -s -o /dev/null -w "%{http_code}"  -H 'host: domain3.org' http://$HOSTNAME:30305/weblogic/
}

function delIng() {
  echo "delete Ingress"
  helm delete --purge domain1-ing-t 
  helm delete --purge domain2-ing-t
  helm delete --purge domain3-ing-t
}

function usage() {
  echo "usage: $0 <cmd>"
  echo "Commands:"
  echo "  createCon: to create the Treafik controller"
  echo
  echo "  delCon: to delete the Treafik controller"
  echo
  echo "  createIng: to create Ingress of domains"
  echo
  echo "  delIng: to delete Ingress of domains"
  echo
  exit 1
}

function main() {
  if [ "$#" != 1 ] ; then
    usage
  fi
  $1
}

main $@
