#!/bin/bash

GITHUB_USER="updater-bot"
GITHUB_USER_EMAIL="updater-bot@fastmail.us"

# check command 
if [[ -z "$(echo 'UPLOAD VALIDATE CHECK' | grep -w "$CMD")" ]]
then
    echo "ERROR: Wrong command received: '$CMD'"
    exit 1
fi

echo ${GITHUB_TOKEN} | gh auth login --with-token > /dev/null 2>&1
if [ -z $? ]
then
    echo "Authorizaton error, update AUTOMATION_TOKEN in repo secrets"
    exit 1
fi

function cleanup {
    # Cleaning up Workspace directory
    rm -rf *
    # Cleaning up home directory
    [[ -d “$HOME” ]] && cd “$HOME” && rm -rf *
    # Cleaning up event.json
    [[ -f “$GITHUB_EVENT_PATH” ]] && rm $GITHUB_EVENT_PATH
}

trap cleanup EXIT

if [ ${CMD} == 'UPLOAD' ]
then
    echo uploading symbol info
    ENVIRONMENT=${GITHUB_REF##*/}
    if [[ -z "$(echo 'production staging' | grep -w "$ENVIRONMENT")" ]]
    then
        echo "ERROR: Wrong environment: '$ENVIRONMENT'. It must be 'production' or 'staging'"
        exit 1
    fi
    git fetch origin --depth=1 > /dev/null 2>&1
    INTEGRATION_NAME=${GITHUB_REPOSITORY##*/}
    for F in $(ls symbols)
    do
        FINAL_NAME=${INTEGRATION_NAME}/$(basename "$F")
        echo uploading symbols/$F to $S3_BUCKET_SYMBOLS/$ENVIRONMENT/$FINAL_NAME
        aws s3 cp "symbols/$F" "$S3_BUCKET_SYMBOLS/$ENVIRONMENT/$FINAL_NAME" --no-progress
        if [ $ENVIRONMENT = "production" ]
        then
            echo uploading $F to $S3_BUCKET_SYMBOLS/staging/$FINAL_NAME
            aws s3 cp "symbols/$F" "$S3_BUCKET_SYMBOLS/staging/$FINAL_NAME" --no-progress
        fi
    done
    if [ $ENVIRONMENT = "production" ]
    then
        echo reseting staging symbols to production version
        git checkout staging && git fetch && git checkout origin/production 'symbols*' && git commit -m "sync with production" && git push origin HEAD
    fi
    exit 0
fi

if [ ${CMD} == 'VALIDATE' ]
then
    echo validete symbol info
    ENVIRONMENT=${GITHUB_BASE_REF}
    if [[ -z "$(echo 'production staging' | grep -w "$ENVIRONMENT")" ]]
    then
        echo "ERROR: Wrong environment: '$ENVIRONMENT'. It must be 'production' or 'staging'"
        exit 1
    fi
    PR_NUMBER=$(jq --raw-output .pull_request.number "$GITHUB_EVENT_PATH")
    git fetch origin --depth=1 > /dev/null 2>&1

    # check for deleted JSON files
    DELETED=$(git diff --name-only --diff-filter=D origin/$ENVIRONMENT)
    if [ -n "$DELETED" ]
    then
        echo "### :red_circle: Deleting JSON files is forbidden" > deleted_report
        echo "#### These files were deleted:" >> deleted_report
        echo "$DELETED" >> deleted_report
        DELETED_REPORT=$(cat deleted_report)
        gh pr review $PR_NUMBER -c -b "$DELETED_REPORT"
        exit 1
    fi

    # check for renamed JSON files
    RENAMED=$(git diff --name-only --diff-filter=R origin/$ENVIRONMENT)
    if [ -n "$RENAMED" ]
    then
        echo "### :red_circle: Renaming JSON files is forbidden" > renamed_report
        echo "#### These files were renamed:" >> renamed_report
        echo "$RENAMED" >> renamed_report
        RENAMED_REPORT=$(cat renamed_report)
        gh pr review $PR_NUMBER -c -b "$RENAMED_REPORT"
        exit 1
    fi

    # check for added JSON files
    ADDED=$(git diff --name-only --diff-filter=A origin/$ENVIRONMENT)
    if [ -n "$ADDED" ]
    then
        echo "### :red_circle: Adding JSON files is forbidden" > added_report
        echo "#### These files were added:" >> added_report
        echo "$ADDED" >> added_report
        ADDED_REPORT=$(cat added_report)
        gh pr review $PR_NUMBER -c -b "$ADDED_REPORT"
        exit 1
    fi

    # validate modified files
    MODIFIED=$(git diff --name-only origin/$ENVIRONMENT | grep ".json$")
    if [ -z "$MODIFIED" ]
    then
        echo No symbol info files were modified
        gh pr review $PR_NUMBER -c -b "No symbol info files (JSON) were modified"
        git checkout $GITHUB_HEAD_REF
        gh pr close $PR_NUMBER --delete-branch
        exit 0
    fi

    # save new versions
    for F in $MODIFIED; do cp "$F" "$F.new"; done

    # save old versions
    git checkout -b old origin/$ENVIRONMENT
    for F in $MODIFIED; do cp "$F" "$F.old"; done

    # download inspect tool
    aws s3 cp "$S3_BUCKET_INSPECT/inspect_r4.12" ./inspect --no-progress && chmod +x ./inspect
    echo inpsect info: $(./inspect version)

    # check files
    FAILED=false

    for F in $MODIFIED
    do
        echo Checking "$F"
        ./inspect symfile --old="$F.old" --new="$F.new" --log-file=stdout --report-file=report.txt --report-format=github
        ./inspect symfile diff --old="$F.old" --new="$F.new" --log-file=stdout
        RESULT=$(grep -c FAIL report.txt)
        echo "#### $F" >> full_report.txt
        cat report.txt >> full_report.txt
        [ "$RESULT" -ne 0 ] && FAILED=true
    done

    FULL_REPORT=$(cat full_report.txt)

    [ $FAILED = "true" ] && gh pr review $PR_NUMBER -c -b "$FULL_REPORT" && echo some tests have failed && exit 1
    [ $FAILED = "false" ] && gh pr review $PR_NUMBER -c -b "$FULL_REPORT"

    echo ready to merge

    # merge PR
    gh pr merge $PR_NUMBER --merge --delete-branch

    exit 0 # pr merge can fail in case of data conflicts, but it is not fail of verification
fi

if [ ${CMD} == 'CHECK' ]
then
    echo "check for update of symbol info"

    if [[ -z "$(echo 'production staging' | grep -w "$ENVIRONMENT")" ]]
    then
        echo "ERROR: Wrong environment: '$ENVIRONMENT'. It must be 'production' or 'staging'"
        exit 1
    fi

    git checkout "${ENVIRONMENT}"
    git fetch origin --depth=1 > /dev/null 2>&1

    PR_PENDING=$(gh pr list --base="${ENVIRONMENT}" --state=open --author="${GITHUB_USER}" | wc -l)

    if (( PR_PENDING > 0 ))
    then
        echo "There is/are ${PR_PENDING} pending pull request(s). Can not create new PR."
        exit 1
    fi

    BRANCH="${EVENT_ID}"
    git checkout -b "${BRANCH}"

    rm -v symbols/*.json

    # download inspect tool
    aws s3 cp "$S3_BUCKET_INSPECT/inspect_r4.12" ./inspect --no-progress && chmod +x ./inspect
    echo inpsect info: $(./inspect version)

    RETRY_PARAMS="--connect-timeout 10 --max-time 10 --retry 5 --retry-delay 0 --retry-max-time 40"
    AUTHORIZATION="Authorization: Bearer ${TOKEN}"
    PREPROCESS=$(cat ./config/preprocess 2> /dev/null)
    IFS=',' read -r -a GROUP_NAMES <<< "$UPSTREAM_GROUPS"
    for GROUP in "${GROUP_NAMES[@]}"
    do
        echo "requesting symbol info for ${GROUP}"
        FILE=${GROUP}.json
        
        if ! curl -s ${RETRY_PARAMS} "${REST_URL}/symbol_info?group=${GROUP}" -H "${AUTHORIZATION}" > "symbols/${FILE}"
        then
            echo "error getting symbol info for ${GROUP}"
            exit 1
        fi

        SYMBOLS_STATUS=$(jq .s "symbols/${FILE}")
        if [ "$SYMBOLS_STATUS" != '"ok"' ] 
        then
            ERROR_MESSAGE=$(jq .errmsg "symbols/${FILE}")
            echo "got not \"ok\" symbols status for ${GROUP}: s: \"$SYMBOLS_STATUS\", errmsg: \"$ERROR_MESSAGE\""
            exit 1
        fi
        
        if [ "${PREPROCESS}" != "" ] 
        then
            jq "${PREPROCESS}" "symbols/${FILE}" > temp.json && mv temp.json "symbols/${FILE}"
            echo "file ${FILE} preprocessed"
        fi

        # if symbol info is valid, the file will be replaced by normalized version
        # don't stop the script execution when normalization fails: pass wrong data to merge request to see problems there
        ./inspect symfile normalize --old "symbols/${FILE}" --new "symbols/${FILE}"

        # remove .s from file in case when inspect didn't normalizate the file
        jq 'del(.s)' "symbols/${FILE}" > temp.json && mv temp.json "symbols/${FILE}"

    done

    MODIFIED=$(git diff --name-only "origin/${ENVIRONMENT}" | grep ".json$")

    if [ -z "${MODIFIED}" ]
    then
        echo "there are no changes"
        exit 0
    fi
    
    git clean -qfx

    git commit -am "automatic symbol info update" && \
    git push origin HEAD && \
    gh pr create --title "Automatic symbol info update" \
    --base "${ENVIRONMENT}" \
    --body "This is an automated update from the updater-bot" \
    --head "${BRANCH}"

    PUSH_RES=$?

    if [ "${PUSH_RES}" != "0" ]
    then
        echo "error on commiting and pushing changes, code ${PUSH_RES}"
        exit 1
    fi

    exit 0
fi
