#!/bin/bash
# Copyright (C) 2023 Alexander Wolz <mail@alexanderwolz.de>


function printHelpMenu(){
    echo ""
    echo "Docker Build Script"
    echo "----------------------------"
    echo "  -a build for current arch"
    echo "  -e pull existing image"
    echo "  -l tag also as latest"
    echo "  -p push image to registry"
    echo "  -r rebuild existing image"
    echo "----------------------------"
    echo "  -h print this menu"
    echo ""
}

##                          ##
##  ------  START --------- ##
##                          ##

#  builds any project with Dockerfile
#   - Gradle projecs
#   - Maven projects (TBD)
#   - NPM projects

CURRENT_FILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

PARENT_DIR="$(dirname $CURRENT_FILE_DIR)"
LOCAL_CONFIG_DIR="$PARENT_DIR/config"
REGISTRY_CONFIG="$LOCAL_CONFIG_DIR/registry.conf"

. $REGISTRY_CONFIG >/dev/null 2>&1
if [ "$?" -ne 0 ]; then
    echo "Warning: ../config/registry.conf not found, create file before using this script!"
fi

#TODO check namespace and registry and ask to proceed if registry is empty

if [ -z "$DOCKER_REGISTRY" ]; then
    echo "DOCKER_REGISTRY not set, using default (registry.hub.docker.com)"
fi


while getopts aelprh opt; do
    case $opt in
    h)
        printHelpMenu
        exit 0
        ;;
    a)
        CURRENT_ARCH=1
        ;;
    e)
        PULL_EXISTING=1
        ;;
    l)
        LATEST=1
        ;;
    p)
        PUSH_IMAGE=1
        ;;
    r)
        REBUILD=1
        ;;
    esac
done

shift $((OPTIND - 1))
[ "${1:-}" = "--" ] && shift

if [ "$#" -lt 1 ]; then
    echo ""
    echo "usage: build.sh [-aelprh] folder"
    printHelpMenu
    exit 1
fi

BUILD_FOLDER=$1
BUILD_TYPE="generic"
DOCKER_FILE=$BUILD_FOLDER/Dockerfile
NPM_PACKAGE=$BUILD_FOLDER/package.json
MVN_PACKAGE=$BUILD_FOLDER/pom.xml
GRADLE_PACKAGE=$BUILD_FOLDER/build.gradle
GRADLE_KOTLIN_PACKAGE=$GRADLE_PACKAGE.kts

if [ ! -d $BUILD_FOLDER ]; then
    echo "$BUILD_FOLDER is not a folder"
    exit 1
fi

if [ ! -f $DOCKER_FILE ]; then
    echo "Folder does not contain Dockerfile"
    exit 1
fi

if [ -f $NPM_PACKAGE ]; then
    BUILD_TYPE="Node"
    IMAGE_NAME=$(grep '"name":' $NPM_PACKAGE | cut -d\" -f4)
    VERSION=$(grep '"version":' $NPM_PACKAGE | cut -d\" -f4)
fi

if [ -f $MVN_PACKAGE ]; then
    BUILD_TYPE="Maven"
    IMAGE_NAME=$(cat $MVN_PACKAGE | grep "^    <artifactId>.*</artifactId>$" | awk -F'[><]' '{print $3}')
    VERSION=$(cat $MVN_PACKAGE | grep "^    <version>.*</version>$" | awk -F'[><]' '{print $3}')
fi

if [ -f $GRADLE_PACKAGE ]; then
    BUILD_TYPE="Gradle"
    SETTINGS=$BUILD_FOLDER/settings.gradle
    IMAGE_NAME=$(grep 'rootProject.name' $SETTINGS | cut -d\' -f2)
    VERSION=$(grep 'version =' $GRADLE_PACKAGE | cut -d\' -f2)
fi

if [ -f $GRADLE_KOTLIN_PACKAGE ]; then
    BUILD_TYPE="Gradle"
    SETTINGS=$BUILD_FOLDER/settings.gradle.kts
    IMAGE_NAME=$(grep 'rootProject.name' $SETTINGS | cut -d\" -f2)
    VERSION=$(grep 'version =' $GRADLE_KOTLIN_PACKAGE | cut -d\" -f2)
fi


if [ -z "$IMAGE_NAME" ]; then
    echo "Could not retrieve image name from $BUILD_TYPE project, aborting.."
    exit 1
fi

if [ -z "$VERSION" ]; then
    echo "Could not retrieve version from $BUILD_TYPE project, aborting.."
    exit 1
fi

if [ ! -z "$DOCKER_REGISTRY" ]; then
    REPO+="$DOCKER_REGISTRY/"
fi

if [ ! -z "$DOCKER_NAMESPACE" ]; then
    REPO+="$DOCKER_NAMESPACE/"
fi

TAG="$VERSION"
TARGET_NAME="$REPO$IMAGE_NAME:$TAG"
TARGET_NAME_LATEST="$REPO$IMAGE_NAME:latest"


echo "Building $BUILD_TYPE project: $IMAGE_NAME v$VERSION (TAG: $TAG)"

docker ps -q >/dev/null 2>&1 # check if docker is running
if [ "$?" -ne 0 ]; then
    echo "Docker engine is not running!"
    exit 1
fi

if [[ $TAG != "latest" && $TAG != "0.0.0" ]]; then
    #check if tag already exists in registry
    docker login $DOCKER_REGISTRY >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "Could not login to registry"
        exit 1
    fi
    docker manifest inspect $TARGET_NAME >/dev/null 2>&1
    if [ "$?" -eq 0 ]; then
        if [ -z "$REBUILD" ]; then
            echo "Image with tag '$TAG' already exists in registry, skipping build."
            docker image inspect $TARGET_NAME >/dev/null 2>&1
            if [ "$?" -ne 0 ]; then
                if [ -z "$PULL_EXISTING" ]; then
                    echo "Image does not exist locally, use -e to pull from registry."
                else
                    echo "Image does not exist locally, pulling.."
                    docker pull $TARGET_NAME >/dev/null 2>&1
                    if [ "$?" -ne 0 ]; then
                        exit 1
                    fi
                    echo "Successfully pulled image."
                fi
            fi
            exit 0
        fi
    fi
fi

BEGIN=$(date +%s)


if [ ! -z "$CURRENT_ARCH" ]; then
    echo "Bulding for $(uname -m)"
    docker build -t $TARGET_NAME $BUILD_FOLDER
    if [ "$?" -ne 0 ]; then
        echo "[ERROR] Docker build unsuccessful!"
        exit 1
    fi
    if [ ! -z "$PUSH_IMAGE" ]; then
        echo "pushing image to $TARGET_NAME"
        docker push $TARGET_NAME
        if [ "$?" -ne 0 ]; then
            echo "[ERROR] Docker push unsuccessful!"
            exit 1
        fi
        if [ ! -z "$LATEST" ]; then
            echo "pushing image to $TARGET_NAME_LATEST"
            docker tag $TARGET_NAME $TARGET_NAME_LATEST
            docker push $TARGET_NAME_LATEST
            if [ "$?" -ne 0 ]; then
                echo "[ERROR] Docker push unsuccessful!"
                exit 1
            fi
        fi
    fi
else
    #multiarch builds
    echo "Creating buildx container.."
    BUILDER_NAME="multiarch"
    CACHE_FOLDER="$PARENT_DIR/.buildx_cache"
    rm -rf $CACHE_FOLDER
    docker buildx rm $BUILDER_NAME > /dev/null
    docker buildx create --platform "linux/amd64,linux/arm64" --name $BUILDER_NAME --use > /dev/null
    OPTIONS=""
    OPTIONS+=" --cache-from=type=local,src=$CACHE_FOLDER"
    OPTIONS+=" --cache-to=type=local,dest=$CACHE_FOLDER"
    if [ ! -z "$PUSH_IMAGE" ]; then
        OPTIONS+=" --push"
        echo "Setting push to $TARGET_NAME"
        if [ ! -z "$LATEST" ]; then
            echo "Setting push to $TARGET_NAME_LATEST"
        fi
    else
        echo "Skipped push"
    fi
    echo "Building image for amd64 and arm64 (host: $(uname -m)).. (tag: $TAG)"
    docker buildx build --platform linux/amd64,linux/arm64 $OPTIONS  -t $TARGET_NAME $BUILD_FOLDER
    if [ "$?" -ne 0 ]; then
        echo "[ERROR] Docker command unsuccessful!"
        docker buildx rm $BUILDER_NAME > /dev/null
        exit 1
    fi

    if [ ! -z "$LATEST" ]; then
        echo "Building image for amd64 and arm64 (host: $(uname -m)).. (tag: latest)"
        docker buildx build --platform linux/amd64,linux/arm64 $OPTIONS -t $TARGET_NAME_LATEST $BUILD_FOLDER
        if [ "$?" -ne 0 ]; then
            echo "[ERROR] Docker command unsuccessful!"
            docker buildx rm $BUILDER_NAME > /dev/null
            exit 1
        fi
    fi

    echo "Cleaning up buildx container.."
    docker buildx rm $BUILDER_NAME > /dev/null
    echo "Cleaning up cache.."
    rm -rf $CACHE_FOLDER
fi

BUILD_TIME=$(($(date +%s) - $BEGIN))
echo "Successfully built docker container in $BUILD_TIME seconds."
