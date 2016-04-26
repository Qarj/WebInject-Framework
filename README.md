# WebInject Framework 0.03

Framework for
* managing WebInject configuration
* running many WebInject automated tests in parallel
* organising actual test run results

This framework is for those with large suites of automated tests. It helps to quickly
answer the question "Did all of our regression tests pass?".

If the answer is no, you can very quickly drill into what went wrong. Since an organised history of previous run results are kept, you can compare a failed result easily against a previous successful run.

## Installation

Install WebInject. (refer to https://github.com/Qarj/WebInject)

From a command prompt:
```
cpan Config::Tiny
```

## Quick Start Guide

### wif.config

This configuration file tells wif.pl where to find various components that it needs.

It also used by wif.pl to store some of the command line options you chose the last time you
invoked wif.pl. The next time you run wif.pl, it will use those options as a default.

There are 3 configuration items that must be set for wif.pl to function:

#### webinject_location

Where to find webinject.pl, relative to where wif.pl is located. If you have placed them
in the same folder, you can simply specify `./`

#### web_server_location_full

Since wif.pl publishes the test run results to a web server for viewing, you need to
specify the root folder location.

On Windows, the default IIS server location is at 'C:\inetpub\wwwroot'

#### web_server_address

This is the base domain (and optionally port) where you will be able to access the results
through a web browser.

For testing wif.pl on your own machine, you can simply put in `localhost`

If you are running the web server on a port other than 80, it can be specified like this `localhost:8080`

### environment_config

In the folder you can give wif.pl information about your web servers, account names, passwords,
and any other details that your WebInject tests need.

The information is specified in a hierarchical way. This means it is possible to have many
'mini-environments' without having to repeat information that is common to each of the mini-environments.
It is often the case in a development environment that you have many teams where each team
has some of their own components, yet shares many other lesser used or lesser changed components with other teams.

For wif.pl quick start purposes, you can leave the configuration as it is. However it is
important to understand how it works for creating your own tests.

#### Level 1: environment_config/_global.config

_global.config contains configuration common to all environments.

#### Level 2: environment_config/DEV.config /PAT.config /PROD.config

All other .config files directly in this folder refer to high level environment names.

In the provided example, three environments have been defined:
    * DEV - development
    * PAT - production acceptance test
    * PROD - production

For wif.pl quick start purposes, you can leave this as it is.

#### Level 3: environment_config/DEV/team1.config etc.

You create sub folders for each high level environment. In there you can create .config
files for each 'mini-environment' as needed. You need to create at least one
mini-environment.

In the provided example, there is an environment called WebInject_examples.config.

Note that for any configuration item provided at a lower level, it will take precedence
over the same configuration specified at a higher level.

### running wif.pl - minimal example

To run an automated test, wif.pl needs to know the:
    * test file to run
    * the high level environment
    * the target 'mini-environment'

```
wif.pl examples/demo.xml --env DEV --target webinject_examples
```

If everything worked ok, wif.pl created a configuration file for WebInject, called
WebInject, ran the tests, then put all the results in your web server location.

Since wif.pl will remember the last test file you ran, and environment details, you
can run it again as follows:

```
wif.pl
```

If you want to run another example, since the environment details have not changed,
you can just specify the test case file:

```
wif.pl examples/get.xml
```

### Viewing the test run results

Assuming you are running a server on localhost, port 80 as suggested by the Quick Setup
Guide, you can view the results from this url:

http://localhost/DEV/Summary.xml
