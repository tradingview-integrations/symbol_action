#!/bin/bash

GITHUB_USER="updater-bot"
GITHUB_USER_EMAIL="updater-bot@fastmail.us"

# check command
if [[ -z "$(echo 'UPLOAD VALIDATE CHECK' | grep -w "$CMD")" ]]
then
    echo "ERROR: Wrong command received: '$CMD'"
    exit 1
fi

if [ ${CMD} == 'VALIDATE' ]; then
    ENVIRONMENT=${GITHUB_BASE_REF}
elif [ ${CMD} == 'CHECK' ]; then
    ENVIRONMENT=${GITHUB_REF##*/}
fi

if [ ${CMD} != 'UPLOAD' ]; then
    # we don't login in UPLOAD CMD because we don't use GH API in this CMD
    if [ ${ENVIRONMENT} == "staging" ]; then
        GH_TOKEN="${GITHUB_TOKEN_STAGING}"
    elif [ ${ENVIRONMENT} == "production" ]; then
        GH_TOKEN="${GITHUB_TOKEN}"
    else
        GH_TOKEN="error"
    fi
    export GITHUB_TOKEN=""
    echo "$(cut -c-6 <<< $GH_TOKEN)"
    echo "$(cut -c-6 <<< $GITHUB_TOKEN)"
    echo $GH_TOKEN | gh auth login --with-token
    if [ $? -ne 0 ]
    then
        echo "Authorizaton error, update GITHUB_TOKEN for ${ENVIRONMENT} environment"
        exit 1
    fi
fi

git config user.name $GITHUB_USER
git config user.email $GITHUB_USER_EMAIL

function cleanup {
    # Cleaning up Workspace directory
    rm -rf *
    # Cleaning up home directory
    [[ -d "$HOME" ]] && cd "$HOME" && rm -rf *
    # Cleaning up event.json
    [[ -f "$GITHUB_EVENT_PATH" ]] && rm $GITHUB_EVENT_PATH
}

function arr2str {
    # join array to string with delimeter
    # example:
    # arr=(1 2 3)
    # arr2str , ${arr[@]} => 1,2,3
    local IFS="$1"
    shift
    if [[ "$IFS" == '\n' ]]; then
        IFS=$'\n'
    fi
    echo "$*";
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
        set -e
        aws s3 cp "symbols/$F" "$S3_BUCKET_SYMBOLS/$ENVIRONMENT/$FINAL_NAME" --no-progress
        set +e
    done
    exit 0
fi

if [ ${CMD} == 'VALIDATE' ]
then
    INSPECT_ARGS=""  # default, but can be rewrite by file in repo
    INSPECT_ARGS_FILE_PATH="./config/inspect_args"

    echo validate symbol info
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
    MODIFIED=($(git diff --name-only origin/$ENVIRONMENT | grep ".json$"))
    if [ -z "$MODIFIED" ]
    then
        echo No symbol info files were modified
        gh pr review $PR_NUMBER -c -b "No symbol info files (JSON) were modified"
        git checkout $GITHUB_HEAD_REF
        gh pr close $PR_NUMBER --delete-branch
        exit 0
    fi

    # validate all json
    MODIFIED=($(find . -wholename "*/symbols/*.json"))
    IFS=$'\n' MODIFIED=($(sort <<<"${MODIFIED[*]}"))
    unset IFS
    # save new versions
    for F in "${MODIFIED[@]}"; do cp "$F" "$F.new"; done

    # save old versions
    git checkout -b old origin/$ENVIRONMENT
    for F in "${MODIFIED[@]}"; do cp "$F" "$F.old"; done

    git checkout $GITHUB_HEAD_REF

    # download inspect tool
    set -e
    aws s3 cp "${S3_BUCKET_INSPECT}/inspect-github-${ENVIRONMENT}" ./inspect --no-progress && chmod +x ./inspect
    inspect_version=$(./inspect version)
    echo "inspect info: ${inspect_version}"
    set +e

    # check files
    FAILED=false

    if [[ -f $INSPECT_ARGS_FILE_PATH ]]; then
        INSPECT_ARGS=$(cat $INSPECT_ARGS_FILE_PATH) > /dev/null 2>&1
        echo "Args for inspect in repo: ${INSPECT_ARGS}"
    else
        echo "No inspect args in repo"
    fi

    arraylength=${#MODIFIED[@]}
    for ((i = 0; i < ${arraylength}; i++)); do
        MODIFIED[i]=$(echo ${MODIFIED[$i]} | cut -c3- | cut -f1 -d".")
    done

    MODIFIED_STR=$(arr2str , ${MODIFIED[@]})
    echo "Checking ${MODIFIED_STR} groups"
    ./inspect symfile --groups="${MODIFIED_STR}" --log-file=stdout --report-file=full_report.txt --report-format=github $INSPECT_ARGS
    ./inspect symfile diff --groups="${MODIFIED_STR}" --log-file=stdout

    FULL_REPORT=$(cat full_report.txt)
    gh pr review $PR_NUMBER -c -b "$FULL_REPORT"

    GROUP_ERR_VALIDATION_STR=$(grep FAIL full_report.txt | cut -f3 -d'*' | uniq)
    readarray -t GROUP_ERR_VALIDATION <<< $GROUP_ERR_VALIDATION_STR

    for err_group in ${GROUP_ERR_VALIDATION[@]};
    do
        mv symbols/$err_group.json.old symbols/$err_group.json # restore previous file version for failed groups
    done;

    err_group_changed=$(git status --porcelain | grep -c ".json$")
    if [[ $err_group_changed -gt 0 ]]; then
        # we restored groups with issue, so we need to push them to branch
        # before push we need to check changes between source and target branch
        # if finally there is no changes between source and target branch --> close this PR
        git add '*.json'
        git commit -m "automatic restore old version for issued groups: $(arr2str , ${GROUP_ERR_VALIDATION[@]})"
        git push
        MODIFIED=($(git diff --name-only origin/$ENVIRONMENT | grep ".json$"))
        if [[ -z "$MODIFIED" ]]; then
            echo "No symbol info files were modified after restoring issued groups from 'origin/${ENVIRONMENT}' branch"
            gh pr review $PR_NUMBER -c -b "No symbol info files (JSON) were modified after restoring issued groups from \`origin/${ENVIRONMENT}\` branch"
            gh pr close $PR_NUMBER --delete-branch
            exit 0
        fi
        msg=$(echo -e "Symbol info wasn't updated for next groups due to issues: \n\`\`\`\n$(arr2str '\n' ${GROUP_ERR_VALIDATION[@]})\n\`\`\`")
        gh pr review $PR_NUMBER -c -b "$msg"
    fi

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
    set -e
    aws s3 cp "${S3_BUCKET_INSPECT}/inspect-github-${ENVIRONMENT}" ./inspect --no-progress && chmod +x ./inspect
    inspect_version=$(./inspect version)
    echo "inspect info: ${inspect_version}"
    set +e

    RETRY_PARAMS="--connect-timeout 10 --max-time 10 --retry 5 --retry-delay 0 --retry-max-time 40"
    if [ "${TOKEN}" != "" ]
    then
        AUTHORIZATION="Authorization: Bearer ${TOKEN}"
    fi

    PREPROCESS=$(cat ./config/preprocess) > /dev/null 2>&1

    if [ -f ./config/currency_convert ]
    then
        CONVERT=1
        if [[ "${ENVIRONMENT}" == "production" ]]
        then
            currency_url='http://s3.amazonaws.com/tradingview-currencies/currencies.json'
        else
            currency_url='http://s3.amazonaws.com/tradingview-currencies-staging/currencies.json'
        fi
        curl --compressed "${currency_url}" | jq '.[] | select(."cmc-id" != "" and ."cmc-id" != null) | {"cmc-id":."cmc-id", "id":."id"}' \
        | jq . -s > currencies.json
        echo "currency.json received"
    else
        CONVERT=0
    fi
    echo "convert currencies ${CONVERT}"

    IFS=',' read -r -a GROUP_NAMES <<< "$UPSTREAM_GROUPS"
    for GROUP in "${GROUP_NAMES[@]}"
    do
        echo "requesting symbol info for ${GROUP}"
        GROUP=${GROUP%:*}   # remove kinds from groupname
        FILE=${GROUP}.json

        if ! curl -s ${RETRY_PARAMS} "${REST_URL}/symbol_info?group=${GROUP}" -H "${AUTHORIZATION}" > "symbols/${FILE}"
        then
            echo "error getting symbol info for ${GROUP}"
            echo "received:"
            echo "-------------------------------"
            cat "symbols/${FILE}"
            echo "-------------------------------"
            exit 1
        fi

        SYMBOLS_STATUS=$(jq .s "symbols/${FILE}")
        if [ "$SYMBOLS_STATUS" != '"ok"' ]
        then
            ERROR_MESSAGE=$(jq .errmsg "symbols/${FILE}")
            echo "got not \"ok\" symbols status for ${GROUP}: s: \"$SYMBOLS_STATUS\", errmsg: \"$ERROR_MESSAGE\""
            echo "received:"
            echo "-------------------------------"
            cat "symbols/${FILE}"
            echo "-------------------------------"
            exit 1
        fi
        # temporary logging of received symbols
        echo "received symbols:"
        jq .symbol "symbols/${FILE}"
        # end of temporary logging of received symbols
        if [ "${PREPROCESS}" != "" ]
        then
            jq "${PREPROCESS}" "symbols/${FILE}" > temp.json && mv temp.json "symbols/${FILE}"

            ## temporary ugly fix of jq behavior with long integers like 1000000000000000000
            to='100000000000000' # 1e+15 is not converted by jq
            for ((i=16; i<=22; i++))
            do
                what="1e+$i"
                to="${to}0"
                sed -i "s/$what/$to/g" "symbols/${FILE}"
            done
            echo "file ${FILE} preprocessed"
        fi

        # if symbol info is valid, the file will be replaced by normalized version
        # don't stop the script execution when normalization fails: pass wrong data to merge request to see problems there
        if ./inspect symfile normalize --groups="symbols/${GROUP}"
        then

            if [ ${CONVERT} == 1 ]
            then
                echo "converting currenciies into ${GROUP}"
                python3 "${1}/map.py" currencies.json "symbols/${FILE}"
                echo "currencies in file ${FILE} are converted"
            fi
        else
            # remove "s" field from file in case when inspect didn't normalizate the file
            # IMPORTANT: don't use `jq` as it can convert some values (for example incorrect int 1.0 to correct 1) ###  jq 'del(.s)' "symbols/${FILE}" > temp.json && mv temp.json "symbols/${FILE}"
            sed -i 's\"s": *"ok" *,\\' symbols/${FILE}
        fi

    done

    MODIFIED=$(git diff --name-only "origin/${ENVIRONMENT}" | grep ".json$")

    if [ -z "${MODIFIED}" ]
    then
        echo "there are no changes"
        exit 0
    fi

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
