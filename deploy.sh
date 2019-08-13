#!/bin/bash

set -e -u

# Set the following environment variables:
# DEPLOY_BUCKET = your bucket name
# DEPLOY_BUCKET_PREFIX = a directory prefix within your bucket
# DEPLOY_BRANCHES = regex of branches to deploy; leave blank for all
# DEPLOY_EXTENSIONS = whitespace-separated file exentions to deploy; leave blank for "jar war zip"
# DEPLOY_FILES = whitespace-separated files to deploy; leave blank for $CIRCLE_BUILD_URL/target/*.$extensions
# AWS_ACCESS_KEY_ID = AWS access ID
# AWS_SECRET_ACCESS_KEY = AWS secret
# AWS_SESSION_TOKEN = optional AWS session token for temp keys
# PURGE_OLDER_THAN_DAYS = Files in the .../deploy and .../pull-request prefixes in S3 older than this number of days will be deleted; leave blank for 90, 0 to disable.
# SKIP_DEPENDENCY_LIST = true to skip the "mvn dependency:list" generation and deployment

CIRCLE_WORKING_DIRECTORY=${CIRCLE_WORKING_DIRECTORY/#\~/$HOME}

if [[ -z "${DEPLOY_BUCKET}" ]]
then
    echo "Bucket not specified via \$DEPLOY_BUCKET"
fi

# CircleCI defined variable only for forked PRs
CIRCLE_PULL_REQUEST=${CIRCLE_PULL_REQUEST:-}
CIRCLE_PR_NUMBER="${CIRCLE_PR_NUMBER:-${CIRCLE_PULL_REQUEST##*/}}"

DEPLOY_BUCKET_PREFIX=${DEPLOY_BUCKET_PREFIX:-}

DEPLOY_BRANCHES=${DEPLOY_BRANCHES:-}

DEPLOY_EXTENSIONS=${DEPLOY_EXTENSIONS:-"jar war zip"}

DEPLOY_SOURCE_DIR=$CIRCLE_WORKING_DIRECTORY$DEPLOY_SOURCE_DIR

PURGE_OLDER_THAN_DAYS=${PURGE_OLDER_THAN_DAYS:-"90"}

SKIP_DEPENDENCY_LIST=${SKIP_DEPENDENCY_LIST:-"false"}

if [[ ! -z "${CIRCLE_PR_NUMBER}" && ! -z "${CIRCLE_PULL_REQUEST}" ]]
then
    target_path=pull-request/${CIRCLE_PR_NUMBER}
elif [[ -z "${DEPLOY_BRANCHES}" || "$CIRCLE_BRANCH" =~ "$DEPLOY_BRANCHES" ]]
then
    target_path=deploy/${CIRCLE_BRANCH////.}/$CIRCLE_BUILD_NUM

else
    echo "Not deploying."
    exit

fi

# BEGIN Circle fold/timer support

activity=""
timer_id=""
start_time=""

circle_start() {
    if [[ -n "$activity" ]]
    then
        echo "Nested circle_start is not supported!"
        return
    fi

    activity="$1"
    timer_id=$RANDOM
    start_time=$(date +%s%N)
    start_time=${start_time/N/000000000} # in case %N isn't supported

    echo "circle_fold:start:$activity"
    echo "circle_time:start:$timer_id"
}

circle_end() {
    if [[ -z "$activity" ]]
    then
        echo "Can't circle_end without circle_start!"
        return
    fi

    end_time=$(date +%s%N)
    end_time=${end_time/N/000000000} # in case %N isn't supported
    duration=$(expr $end_time - $start_time)
    echo "circle_time:end:$timer_id:start=$start_time,finish=$end_time,duration=$duration"
    echo "circle_fold:end:$activity"

    # reset
    activity=""
    timer_id=""
    start_time=""
}

# END Circle fold/timer support

discovered_files=""
for ext in ${DEPLOY_EXTENSIONS}
do
    discovered_files+=" $(ls $DEPLOY_SOURCE_DIR/*.${ext} 2>/dev/null || true)"
done

files=${DEPLOY_FILES:-$discovered_files}

if [[ -z "${files// }" ]]
then
    echo "Files not found; not deploying."
    exit 1
fi

target=builds/${DEPLOY_BUCKET_PREFIX}${DEPLOY_BUCKET_PREFIX:+/}$target_path/

if [[ "$SKIP_DEPENDENCY_LIST" != "true" ]]
then
    # Write dependency-list.txt and include it in the upload
    circle_start "dependency_list"
    mvn -q -B dependency:list -Dsort=true -DoutputType=text -DoutputFile=target/dependency-list.txt || echo "dependency-tree.txt generation failed"
    circle_end

    if [[ -f "$DEPLOY_SOURCE_DIR/dependency-list.txt" ]]
    then
        files+=" $DEPLOY_SOURCE_DIR/dependency-list.txt"
    fi
fi

if ! [ -x "$(command -v aws)" ]; then
    circle_start "pip"
    pip install --upgrade --user awscli
    circle_end
    export PATH=~/.local/bin:$PATH
fi

circle_start "aws_cp"
for file in $files
do
    aws s3 cp $file s3://$DEPLOY_BUCKET/$target
done
circle_end

if [[ $PURGE_OLDER_THAN_DAYS -ge 1 ]]
then
    circle_start "clean_s3"
    echo "Cleaning up builds in S3 older than $PURGE_OLDER_THAN_DAYS days . . ."

    cleanup_prefix=builds/${DEPLOY_BUCKET_PREFIX}${DEPLOY_BUCKET_PREFIX:+/}
    # TODO: this works with GNU date only
    older_than_ts=`date -d"-${PURGE_OLDER_THAN_DAYS} days" +%s`

    for suffix in deploy pull-request
    do
        aws s3api list-objects --bucket $DEPLOY_BUCKET --prefix $cleanup_prefix$suffix/ --output=text | \
        while read -r line
        do
            last_modified=`echo "$line" | awk -F'\t' '{print $4}'`
            if [[ -z $last_modified ]]
            then
                continue
            fi
            last_modified_ts=`date -d"$last_modified" +%s`
            filename=`echo "$line" | awk -F'\t' '{print $3}'`
            if [[ $last_modified_ts -lt $older_than_ts ]]
            then
                if [[ $filename != "" ]]
                then
                    echo "s3://$DEPLOY_BUCKET/$filename is older than $PURGE_OLDER_THAN_DAYS days ($last_modified). Deleting."
                    aws s3 rm s3://$DEPLOY_BUCKET/$filename
                fi
            fi
        done
    done
    circle_end
fi
