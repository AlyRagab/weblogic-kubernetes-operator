#!/usr/bin/env bash
# Copyright (c) 2018, 2019, Oracle Corporation and/or its affiliates. All rights reserved.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

# This script contains the all the function of model in image
# It is used by introspectDomain.sh job and starServer.sh

source ${SCRIPTPATH}/utils.sh

declare -A inventory_image
declare -A inventory_cm
declare -A inventory_passphrase
inventory_image_md5="/weblogic-operator/introspectormd5/inventory_image.md5"
inventory_cm_md5="/weblogic-operator/introspectormd5/inventory_cm.md5"
inventory_passphrase_md5="/weblogic-operator/introspectormd5/inventory_passphrase.md5"
inventory_merged_model="/weblogic-operator/introspectormd5/merged_model.json"
inventory_wls_version="/weblogic-operator/introspectormd5/wls.version"
inventory_jdk_path="/weblogic-operator/introspectormd5/jdk.path"
inventory_secrets_md5="/weblogic-operator/introspectormd5/secrets.md5"
domain_zipped="/weblogic-operator/introspectormd5/domainzip.secure"
wdt_config_root="/weblogic-operator/wdt-config-map"
wdt_encryption_passphrase="/weblogic-operator/wdt-encrypt-key-passphrase/passphrase"
opss_key_passphrase="/weblogic-operator/opss-key-passphrase/passphrase"
model_home="/u01/wdt/models"
model_root="${model_home}"
archive_root="${model_home}"
variable_root="${model_home}"
wdt_bin="/u01/wdt/weblogic-deploy/bin"
operator_md5=${DOMAIN_HOME}/operatormd5
archive_zip_changed=0
UNSAFE_ONLINE_UPDATE=0
SAFE_ONLINE_UPDATE=1
FATAL_MODEL_CHANGES=2
MODELS_SAME=3
ROLLBACK_ERROR=3
SCRIPT_ERROR=255


# sort the files according to the pattern and
# and write the result in a sequence array to stdout

function sort_files() {
  shopt -s nullglob
  root_dir=$1
  ext=$2
  declare -A sequence_array
  for file in ${root_dir}/*${ext} ;
    do
      actual_filename=$(basename $file)
      base_filename=$(basename ${file%.*})
      sequence="${base_filename##*.}"
      sequence_array[${actual_filename}]=${sequence}
    done
  for k in "${!sequence_array[@]}" ;
    do
      # MUST use echo , caller depends on stdout
      echo $k ' - ' ${sequence_array["$k"]}
    done |
  sort -n -k3  | cut -d' ' -f 1
  shopt -u nullglob
}

# compare the current MD5 list of WDT artifacts against
# the one keep in the introspect cm
#  return 0 - nothing has changed
#         1 - something has changed or new additions, deletions

function checkExistInventory() {
  has_md5=0

  trace "Checking model in image"


  if [ -f ${inventory_image_md5} ] ; then
    source -- ${inventory_image_md5}
    has_md5=1
    if [ ${#introspect_image[@]} -ne ${#inventory_image[@]} ]; then
      trace "Contents in model home changed: create domain again"
      return 1
    fi
    for K in "${!inventory_image[@]}"; do
      extension="${K##*.}"
      if [ "$extension" == "yaml" -o "$extension" == "properties" -o "$extension" == "zip" ]; then
        if [ ! "${inventory_image[$K]}" == "${introspect_image[$K]}" ]; then
          trace "md5 not equal: create domain" $K
          archive_zip_changed=1
          return 1
        fi
      fi
    done
  fi

  trace "Checking images in config map"
  if [ -f ${inventory_cm_md5} ] ; then
    source -- ${inventory_cm_md5}
    has_md5=1
    if [ ${#introspect_cm[@]} -ne ${#inventory_cm[@]} ]; then
      trace "Contents of config map changed: create domain again"
      return 1
    fi
    for K in "${!inventory_cm[@]}"; do
      extension="${K##*.}"
      if [ "$extension" == "yaml" -o "$extension" == "properties" ]; then
        if [ ! "${inventory_cm[$K]}" == "${introspect_cm[$K]}" ]; then
          trace "md5 not equal: create domain" $K
          return 1
        fi
      fi
     done
  else
    # if no config map before but adding one now
    if [ ${#inventory_cm[@]} -ne 0 ]; then
      trace "New inventory in cm: create domain"
      return 1
    fi
  fi

  trace "Checking passphrase"
  if [ -f ${inventory_passphrase_md5} ] ; then
    has_md5=1
    source -- ${inventory_passphrase_md5}
    #found_wdt_pwd=$(find ${wdt_secret_path} -name wdtpassword -type f)
    if [ -f "${wdt_encryption_passphrase}" ] ; then
      target_md5=$(md5sum ${wdt_encryption_passphrase} | cut -d' ' -f1)
    fi
    for K in "${!inventory_passphrase[@]}"; do
      if [ ! "$target_md5" == "${inventory_passphrase[$K]}" ]; then
        trace "passphrase changed: recreate domain " $target_md5 ${inventory_passphrase[$K]}
        return 1
      fi
    done
  else
    if [ ${#inventory_passphrase[@]} -ne 0 ]; then
      trace "new passphrase: recreate domain"
      return 1
    fi
  fi

  if [ $has_md5 -eq 0 ]; then
    trace "no md5 found: create domain"
    return 1
  fi
  return 0

}


#
# return opss key wallet ewallet.p12 location
# if there is one from the user config map, use it first
# otherwise use the one in the introspect job config map
#

function get_opss_key_wallet() {
  if [ -d /weblogic-operator/opss-key-wallet ] ; then
   found_wallet=$(find /weblogic-operator/opss-key-wallet -name ewallet.p12 -type f)
  fi
  if [ ! -z ${found_wallet} ] && [ -f ${found_wallet} ] ; then
    echo ${found_wallet}
  else
    echo "/weblogic-operator/introspectormd5/ewallet.p12"
  fi
}

#
# Setup the MD5 inventory for comparison between updates and store in confgimap
#  Also setup the wdt parameters
#

function setupInventoryList() {
  model_list=""
  archive_list=""
  variable_list="${model_home}/_k8s_generated_props.properties"
  local version_changed=0

  # in case retry
  if [ -f ${variable_list} ] ; then
    cat /dev/null > ${variable_list}
  fi

  if [ $# -eq 1 ] && [ $1 -eq 1 ] ; then
    version_changed=1
  fi

  #
  # First build the command line parameters for WDT
  # based on the file listing in the image or config map
  #

  for file in $(sort_files $model_root ".yaml") ;
    do
      inventory_image[$file]=$(md5sum ${model_root}/${file} | cut -d' ' -f1)
      if [ "$model_list" != "" ]; then
        model_list="${model_list},"
      fi
      model_list="${model_list}${model_root}/${file}"
    done

  for file in $(sort_files $wdt_config_root ".yaml") ;
    do
      inventory_cm[$file]=$(md5sum ${wdt_config_root}/$file | cut -d' ' -f1)
      if [ "$model_list" != "" ]; then
        model_list="${model_list},"
      fi
      model_list="${model_list}${wdt_config_root}/${file}"
    done

  for file in $(sort_files ${archive_root} "*.zip") ;
    do
      inventory_image[$file]=$(md5sum ${archive_root}/$file | cut -d' ' -f1)
      if [ "$archive_list" != "" ]; then
        archive_list="${archive_list},"
      fi
      archive_list="${archive_list}${archive_root}/${file}"
    done

  # Merge all properties together

  for file in $(sort_files ${variable_root} ".properties") ;
    do
      inventory_image[$file]=$(md5sum ${variable_root}/$file | cut -d' ' -f1)
      cat ${variable_root}/${file} >> ${variable_list}
    done

  for file in $(sort_files ${wdt_config_root} ".properties") ;
    do
      inventory_cm[$file]=$(md5sum  ${wdt_config_root}/$file | cut -d' ' -f1)
      cat ${wdt_config_root}/${file} >> ${variable_list}
    done

  if [ -f ${variable_list} ]; then
    variable_list="-variable_file ${variable_list}"
  else
    variable_list=""
  fi

  if [ "$archive_list" != "" ]; then
    archive_list="-archive_file ${archive_list}"
  fi

  if [ "$model_list" != "" ]; then
    model_list="-model_file ${model_list}"
  fi

  use_encryption=""
  use_passphrase=0
  if [ -f "${wdt_encryption_passphrase}" ] ; then
    inventory_passphrase[wdtpassword]=$(md5sum $(wdt_encryption_passphrase) | cut -d' ' -f1)
    wdt_passphrase=$(cat $(wdt_encryption_passphrase))
    use_passphrase=1
  fi

  #found_opss_passphrase=$(find ${wdt_secret_path} -name opsspassphrase -type f)
  if [ -f "${opss_key_passphrase}" ] ; then
    export OPSS_PASSPHRASE=$(cat $(opss_key_passphrase))
  fi
  # just in case is not set
  if [ -z "${OPSS_PASSPHRASE}" ] ; then
    export OPSS_PASSPHRASE=${DOMAIN_UID}_welcome1
  fi



  # We need to run wdt create to get a new merged model
  # otherwise for the update case we won't have one to compare with

  if [ -z "${WDT_DOMAIN_TYPE}" ] ; then
    WDT_DOMAIN_TYPE=WLS
  fi

  #  We cannot strictly run create domain for JRF type because it's tied to a database schema
  #  We shouldn't require user to drop the db first since it may have data in it
  #  Can we safely switch to use WLS as type.
  #
  opss_wallet=$(get_opss_key_wallet)
  if [ -f "${opss_wallet}" ] && [ ${version_changed} -eq 0 ] ; then
    if [ ! -z ${KEEP_JRF_SCHEMA} ] && [ ${KEEP_JRF_SCHEMA} == "true" ] ; then
      trace "keeping rcu schema"
      mkdir -p /tmp/opsswallet
      base64 -d  ${opss_wallet} > /tmp/opsswallet/ewallet.p12
      OPSS_FLAGS="-opss_wallet /tmp/opsswallet -opss_wallet_passphrase ${OPSS_PASSPHRASE}"
    fi
  else
    OPSS_FLAGS=""
  fi

}

# Some refactoring is needed
# 1. Create the parameter list for WDT
# 2. Check if any WDT artifacts changed
# 3. If nothing changed return 0
# 4. If somethin changed (or new) then use WDT createDomain.sh
# 5. With the new domain created, the generated merged model is compare with the previous one (if any)
# 6. If there are safe changes and  user select useOnlineUpdate, use wdt online update
# 6.1.   if online update failed then exit the introspect job
# 6.2    if online update succeeded and no restart is need then go to 7.1
# 6.3    if online update succeeded and restart is needed but user set rollbackIfRequireRestart then exit the job
# 6.4    go to 7.1.
# 7. else
# 7.1    unzip the old domain and use wdt offline updates


function createWLDomain() {


  # check to see if any model including changed (or first model in image deploy)
  # if yes. then run create domain again

  local current_version=$(getWebLogicVersion)
  local current_jdkpath=$(readlink -f $JAVA_HOME)
  # check for version:  can only be rolling

  local version_changed=0
  local jdk_changed=0
  local secrets_changed=0
  trace "current version "${current_version}

  getSecretsMD5
  local current_secrets_md5=$(cat /tmp/secrets.md5)

  if [ -f ${inventory_secrets_md5} ] ; then
    previous_secrets_md5=$(cat ${inventory_secrets_md5})
    if [ "${current_secrets_md5}" != "${previous_secrets_md5}" ]; then
      trace "secrets different: before: ${previous_secrets_md5} current: ${current_secrets_md5}"
      secrets_changed=1
    fi
  fi

  if [ -f ${inventory_wls_version} ] ; then
    previous_version=$(cat ${inventory_wls_version})
    if [ "${current_version}" != "${previous_version}" ]; then
      trace "version different: before: ${previous_version} current: ${current_version}"
      version_changed=1
    fi
  fi

  if [ -f ${inventory_jdk_path} ] ; then
    previous_jdkpath=$(cat ${inventory_jdk_path})
    if [ "${current_jdkpath}" != "${previous_jdkpath}" ]; then
      trace "jdkpath different: before: ${previous_jdkpath} current: ${current_jdkpath}"
      jdk_changed=1
    fi
  fi

  # write out version, introspectDomain.py will write it to the configmap

  echo ${current_version} > /tmp/wls_version
  echo $(readlink -f $JAVA_HOME) > /tmp/jdk_path

  # setup wdt parameters and also associative array before calling comparing md5 in checkExistInventory
  #
  setupInventoryList ${version_changed}

  checkExistInventory
  local wdt_artifacts_changed=$?
  # something changed in the wdt artifacts or wls version changed
  local created_domain=0
  if  [ ${wdt_artifacts_changed} -ne 0 ] || [ ${version_changed} -eq 1 ] || [ ${jdk_changed} -eq 1 ] \
    || [ ${secrets_changed} -ne 0 ] ; then

    trace "Need to create domain ${WDT_DOMAIN_TYPE}"
    wdtCreateDomain
    created_domain=1

    # For lifecycle updates:
    # 1. If there is a merged model in the cm and
    # 2. If the archive changed and
    # 3. If the useOnlineUpdate is define in the spec and set to true and
    # 4. not for version upgrade

    if [ -f ${inventory_merged_model} ] && [ ${archive_zip_changed} -eq 0 ] && [ "true" == "${USE_ONLINE_UPDATE}" \
            ] && [ ${version_change} -ne 1 ]; then

      ${SCRIPTPATH}/wlst.sh ${SCRIPTPATH}/model_diff.py ${DOMAIN_HOME}/wlsdeploy/domain_model.json \
          ${inventory_merged_model}
      diff_rc=$?
      trace "model diff returns "${diff_rc}
      cat /tmp/diffed_model.json

      # 0 not safe
      # 1 safe for online changes
      # 2 fatal
      # 3 no difference

      # Perform online changes
      if [ ${diff_rc} -eq ${SCRIPT_ERROR} ]; then
        exit 1
      fi

      if [ ${diff_rc} -eq ${SAFE_ONLINE_UPDATE} ] ; then
        trace "Using online update"
        handleOnlineUpdate
      fi

      # Changes are not supported - shape changes
      if [ ${diff_rc} -eq ${FATAL_MODEL_CHANGES} ] ; then
        trace "Introspect job terminated: Unsupported changes in the model is not supported"
        exit 1
      fi

      if [ ${diff_rc} -eq ${MODELS_SAME} ] ; then
        trace "Introspect job terminated: Nothing changed"
        return 0
      fi

      # Changes are not supported yet for online update - non shape changes.. deletion, deploy app.
      # app deployments may involve shared libraries, shared library impacted apps, although WDT online support
      # it but it has not been fully tested - forbid it for now.

      if [ ${diff_rc} -eq ${UNSAFE_ONLINE_UPDATE} ] ; then
        trace "Introspect job terminated: Changes are not safe to do online updates. Use offline changes. See introspect job logs for
        details"
        exit 1
      fi
    fi

    # The reason for copying the associative array is because they cannot be passed to the function for checking
    # and the script source the persisted associative variable shell script to retrieve it back to a variable
    # we are comparing  inventory* (which is the current image md5 contents) vs introspect* (which is the previous
    # run stored in the config map )

    if [ "${#inventory_image[@]}" -ne "0" ] ; then
      declare -A introspect_image
      for K in "${!inventory_image[@]}"; do introspect_image[$K]=${inventory_image[$K]}; done
      declare -p introspect_image > /tmp/inventory_image.md5
    fi
    if [ "${#inventory_cm[@]}" -ne "0" ] ; then
      declare -A introspect_cm
      for K in "${!inventory_cm[@]}"; do introspect_cm[$K]=${inventory_cm[$K]}; done
      declare -p introspect_cm > /tmp/inventory_cm.md5
    fi
    if [ "${#inventory_passphrase[@]}" -ne "0" ] ; then
      declare -A introspect_passphrase
      for K in "${!inventory_passphrase[@]}"; do introspect_passphrase[$K]=${inventory_passphrase[$K]}; done
      declare -p introspect_passphrase > /tmp/inventory_passphrase.md5
    fi

  fi
  return ${created_domain}
}

# getSecretsMD5
#
# jar up all the secrets, calculate the md5 and delete the file.
# The md5 is used to determine whether the domain needs to be recreated
# Note: the secrets are two levels indirections, so use find and filter out the ..data
#
function getSecretsMD5() {
  local jarname="/tmp/secrets.txt"
  local override_secrets="/weblogic-operator/config-overrides-secrets/"
  local weblogic_secrets="/weblogic-operator/secrets/"
  local tmp_secrets="/tmp/tmpsecrets"

  if [ -d "${override_secrets}" ] ; then
    find $override_secrets -type l -not -name "..data" -print | xargs cat > ${jarname}
  fi

  if [ -d "${weblogic_secrets}" ] ; then
    find ${weblogic_secrets} -type l -not -name "..data" -print | xargs cat >> ${jarname}
  fi

  if [ ! -f "${jarname}" ] ; then
    echo "0" > ${jarname}
  fi
  secrets_md5=$(md5sum ${jarname} | cut -d' ' -f1)
  echo ${secrets_md5} > /tmp/secrets.md5
  trace "Found secrets ${secrets_md5}"

  rm ${jarname}
}
#
# User WDT create domain
#

function wdtCreateDomain() {

  export __WLSDEPLOY_STORE_MODEL__=1

  if [ $use_passphrase -eq 1 ]; then
    yes ${wdt_passphrase} | ${wdt_bin}/createDomain.sh -oracle_home ${MW_HOME} -domain_home \
    ${DOMAIN_HOME} ${model_list} ${archive_list} ${variable_list} -use_encryption -domain_type
    ${WDT_DOMAIN_TYPE} \
    ${OPSS_FLAGS}
  else
    ${wdt_bin}/createDomain.sh -oracle_home ${MW_HOME} -domain_home ${DOMAIN_HOME} $model_list \
    ${archive_list} ${variable_list}  -domain_type ${WDT_DOMAIN_TYPE} ${OPSS_FLAGS}
  fi
  ret=$?
  if [ $ret -ne 0 ]; then
    trace "Create Domain Failed"
    exit 1
  fi

}

function handleOnlineUpdate() {

  cp ${DOMAIN_HOME}/wlsdeploy/domain_model.json /tmp/domain_model.json.new
  admin_user=$(cat /weblogic-operator/secrets/username)
  admin_pwd=$(cat /weblogic-operator/secrets/password)


  ROLLBACK_FLAG=""
  if [ ! -z "${ROLLBACK_IF_REQUIRE_RESTART}" ] && [ "${ROLLBACK_IF_REQUIRE_RESTART}" == "true" ]; then
      ROLLBACK_FLAG="-rollback_if_require_restart"
  fi
  # no need for encryption phrase because the diffed model has real value
  # note: using yes seems to et a 141 return code, switch to echo seems to be ok
  # the problem is likely due to how wdt closing the input stream


  echo ${admin_pwd} | ${wdt_bin}/updateDomain.sh -oracle_home ${MW_HOME} \
   -admin_url "t3://${AS_SERVICE_NAME}:${ADMIN_PORT}" -admin_user ${admin_user} -model_file \
   /tmp/diffed_model.json -domain_home ${DOMAIN_HOME} ${ROLLBACK_FLAG}

  ret=$?

  echo "Completed online update="${ret}

  if [ ${ret} -eq ${ROLLBACK_ERROR} ] ; then
    trace ">>>  updatedomainResult=3"
    exit 1
  elif [ ${ret} -ne 0 ] ; then
    trace "Introspect job terminated: Online update failed. Check error in the logs"
    trace "Note: Changes in the optional configmap and/or image may needs to be correction"
    trace ">>>  updatedomainResult=${ret}"
    exit 1
  else
    trace ">>>  updatedomainResult=${ret}"
  fi

  trace "wrote updateResult"

  # if online update is successful, then we extract the old domain and use offline update, so that
  # we can update the domain and reuse the old ldap
  rm -fr ${DOMAIN_HOME}
  cd / && base64 -d ${domain_zipped} > /tmp/domain.tar.gz && tar -xzvf /tmp/domain.tar.gz
  chmod +x ${DOMAIN_HOME}/bin/*.sh ${DOMAIN_HOME}/*.sh

  # We do not need OPSS key for offline update

  ${wdt_bin}/updateDomain.sh -oracle_home ${MW_HOME} \
   -model_file /tmp/diffed_model.json ${variable_list} -domain_home ${DOMAIN_HOME} -domain_type \
   ${WDT_DOMAIN_TYPE}

  mv  /tmp/domain_model.json.new ${DOMAIN_HOME}/wlsdeploy/domain_model.json

}
