# CircleCI S3 Deploy Script

This script is used by [Circle CI](https://circleci.com/) to continuously deploy artifacts to an S3 bucket.

When Circle builds a push to your project (not a pull request), any files matching `target/*.{war,jar,zip}` will be uploaded to your S3 bucket with the prefix `builds/$DEPLOY_BUCKET_PREFIX/deploy/$BRANCH/$BUILD_NUMBER/`. Pull requests will upload the same files with a prefix of `builds/$DEPLOY_BUCKET_PREFIX/pull-request/$PULL_REQUEST_NUMBER/`.

For example, the 36th push to the `master` branch will result in the following files being created in your `exampleco-ops` bucket:

```
builds/exampleco/deploy/master/36/exampleco-1.0-SNAPSHOT.war
builds/exampleco/deploy/master/36/exampleco-1.0-SNAPSHOT.zip
```

When the 15th pull request is created, the following files will be uploaded into your bucket:
```
builds/exampleco/pull-request/15/exampleco-1.0-SNAPSHOT.war
builds/exampleco/pull-request/15/exampleco-1.0-SNAPSHOT.zip
```

## Prerequisites

Your project must be compiled with Gradle in order for builds to be cached. Maven can be compiled 
in Circle but at a significant performance premium.

## Usage

Your .circleci/config.yml should look something like this:

```yaml
version: 2.1
orbs:
  aws-cli: circleci/aws-cli@0.1.13
jobs:
  build:
    docker:
      - image: circleci/openjdk:8u171-jdk
    environment:
      _JAVA_OPTIONS: "-Xmx6g"
    steps:
      - checkout
      - run:
          name: Export Environment Variables
          command: |
            echo 'export DEPLOY_SOURCE_DIR=/site/target' >> $BASH_ENV
      - run:
          name: Build steps
          command: |
            mvn -B package
      - aws-cli/install
      - deploy:
          command: |
            git clone https://github.com/perfectsense/circle-s3-deploy.git && ./circle-s3-deploy/deploy.sh
```

Note that any of the above environment variables can be set in Circle, and do not need to be included in your config.yml. `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` should always be set to your S3 bucket credentials as environment variables in Circle, not this file.
