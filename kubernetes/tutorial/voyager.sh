#!/bin/bash
# Copyright 2019, Oracle Corporation and/or its affiliates.  All rights reserved.
# Licensed under the Universal Permissive License v 1.0 as shown at http://oss.oracle.com/licenses/upl.

set -u

source ./waitUntil.sh
function createCon() {
  echo "install Voyager controller to namespace voyager"
  $WLS_OPT_ROOT/kubernetes/samples/charts/util/setup.sh create voyager
}

function delCon() {
  echo "delete Voyager controller"
  $WLS_OPT_ROOT/kubernetes/samples/charts/util/setup.sh delete voyager
}

function createIng() {
  echo "install Ingress for domains"
  kubectl create -f ings/voyager-ings.yaml
  waitUntilHAProxyReady
  waitUntilHTTPReady Domain1
  waitUntilHTTPReady Domain2
  waitUntilHTTPReady Domain3
}

function waitUntilHAProxyReady() {
  expected_out=1
  okMsg="Voyager/HAProxy pod is ready"
  failMsg="fail to start Voyager/HAProxy pod"

  waitUntil "checkHAProxyReadyCmd" "$expected_out" "$okMsg" "$failMsg"
}

function checkHAProxyReadyCmd() {
  kubectl get pod | grep voyager-ing | grep 1/1 | wc -l
}

function waitUntilHTTPReady() {
  expected_out=200
  okMsg="load balancing traffic to $1 is ready"
  failMsg="fail to load balancing traffic to $1 "

  waitUntil "checkHTTP${1}Cmd" "$expected_out" "$okMsg" "$failMsg"
}

function checkHTTPDomain1Cmd() {
  curl -s -o /dev/null -w "%{http_code}"  -H 'host: domain1.org' http://$HOSTNAME:30307/weblogic/
}

function checkHTTPDomain2Cmd() {
  curl -s -o /dev/null -w "%{http_code}"  -H 'host: domain2.org' http://$HOSTNAME:30307/weblogic/
}

function checkHTTPDomain3Cmd() {
  curl -s -o /dev/null -w "%{http_code}"  -H 'host: domain3.org' http://$HOSTNAME:30307/weblogic/
}


function delIng() {
  echo "delete Ingress"
  kubectl delete -f ings/voyager-ings.yaml
}

function usage() {
  echo "usage: $0 <cmd>"
  echo "Commands:"
  echo "  createCon: to create the Voyager controller"
  echo
  echo "  delCon: to delete the Voyager controller"
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
