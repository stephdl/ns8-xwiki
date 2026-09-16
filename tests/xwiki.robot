*** Settings ***
Library    SSHLibrary

*** Variables ***
${CLUSTER_USER}     admin
${CLUSTER_PASSWORD}    Nethesis,1234
${TEST_HOST}    xwiki.ns8-ci.test

*** Test Cases ***
Check if xwiki is installed correctly
    ${output}  ${rc} =    Execute Command    add-module ${IMAGE_URL} 1
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    &{output} =    Evaluate    ${output}
    Set Suite Variable    ${module_id}    ${output.module_id}

Check if xwiki can be configured
    ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"host":"${TEST_HOST}","lets_encrypt":false}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Check if xwiki configuration reads back
    ${output}  ${rc} =    Execute Command    api-cli run module/${module_id}/get-configuration --data '{}'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    ${config} =    Evaluate    json.loads('''${output}''')    modules=json
    Should Be Equal    ${config}[host]    ${TEST_HOST}

Check if the xwiki virtualhost answers
    Wait Until Keyword Succeeds    300s    10s    xwiki answers behind Traefik

Check if the generated configuration carries the host
    # bin/generate-xwiki-cfg and generate-xwiki-properties render these two
    # files at every start, and state-include.conf backs them up
    ${output}  ${rc} =    Execute Command
    ...    runagent -m ${module_id} bash -c 'grep -c . $AGENT_STATE_DIR/xwiki.cfg $AGENT_STATE_DIR/xwiki.properties'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    Should Not Contain    ${output}    :0

Check if the database dump is consistent
    # state-include.conf lists state/xwiki.sql, produced by module-dump-state
    ${rc} =    Execute Command    runagent -m ${module_id} module-dump-state
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
    ${output}  ${rc} =    Execute Command
    ...    runagent -m ${module_id} bash -c 'head -3 $AGENT_STATE_DIR/xwiki.sql'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    Should Contain    ${output}    MariaDB dump

Check if the database passwords stay in state
    # They live in state/passwords.env, never in Redis: the module environment
    # must not carry them
    ${output}  ${rc} =    Execute Command
    ...    runagent -m ${module_id} bash -c 'grep -c PASSWORD $AGENT_STATE_DIR/passwords.env; cat $AGENT_STATE_DIR/environment'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    Should Not Contain    ${output}    DB_ROOT_PASSWORD=

Check if the services are running
    ${rc} =    Execute Command
    ...    runagent -m ${module_id} systemctl --user is-active xwiki.service xwiki-app.service mariadb-app.service
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Check if a configuration without the host is refused
    # The agent exits 10 on a JSON Schema input validation failure
    ${errors}  ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"lets_encrypt":false}'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  10
    Should Contain    ${errors}    host

Take screenshots of the module pages
    [Documentation]    Capture what cluster-admin shows, for the software center
    ...                entry. Tagged ui: the shared runner skips it unless
    ...                RUN_UI_TESTS is true, since it needs a browser.
    [Tags]    ui
    Import Library    Browser
    New Browser    chromium    headless=True
    New Context    ignoreHTTPSErrors=True    viewport={'width': 1280, 'height': 900}
    Login to cluster-admin
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}
    Wait For Elements State    iframe >>> h2 >> text="Status"    visible    timeout=10s
    # The page fills itself from several tasks: let them land
    Sleep    5s
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/1._Status.png
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}?page=settings
    Wait For Elements State    iframe >>> h2 >> text="Settings"    visible    timeout=10s
    Sleep    5s
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/2._Settings.png
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}?page=about
    Wait For Elements State    iframe >>> h2 >> text="About"    visible    timeout=10s
    Sleep    5s
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/3._About.png
    Close Browser

Check if xwiki is removed correctly
    ${rc} =    Execute Command    remove-module --no-preserve ${module_id}
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

*** Keywords ***
Login to cluster-admin
    New Page    https://${NODE_ADDR}/cluster-admin/
    Fill Text    text="Username"    ${CLUSTER_USER}
    Click    button >> text="Continue"
    Fill Text    text="Password"    ${CLUSTER_PASSWORD}
    Click    button >> text="Log in"
    Wait For Elements State    css=#main-content    visible    timeout=10s

xwiki answers behind Traefik
    # configure_traefik hardcodes http2https, so the route only answers on TLS,
    # with a self-signed certificate the node generated for itself.
    #
    # Deliberately weak: this asserts a non-empty body rather than a string,
    # because a status check alone passes on an empty 302 and I could not
    # verify what a configured instance serves. Tighten it with a real marker
    # once known, the way ns8-pihole greps <form id="loginform">.
    # --resolve rather than a Host header: the root redirects, and curl must be
    # able to follow it whether the Location comes back relative or absolute.
    ${output}  ${rc} =    Execute Command
    ...    curl -fsSkL --resolve ${TEST_HOST}:443:127.0.0.1 --resolve ${TEST_HOST}:80:127.0.0.1 https://${TEST_HOST}/
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    Should Not Be Empty    ${output}
