#!/bin/bash

GIT_PATH="toxcore-git"
OUTPUT="toxcore"

DIRS=(
    "toxcore"
    "toxav"
    "toxdns"
    "toxencryptsave"
)

echo "Removing old toxcore directory"
rm -rf $OUTPUT
mkdir $OUTPUT

for dir in ${DIRS[@]}; do
    echo "Copying files from $GIT_PATH/$dir to $OUTPUT/$dir"
    cp -rv $GIT_PATH/$dir $OUTPUT
done

echo "Changing all .c files to .m files (making Xcode happy)"
for file in toxcore/**/*.c; do
    mv -v "$file" "${file%.c}.m"
done

echo "Applying install-tox.patch"
git apply install-tox.patch

echo "Renaming toxav/group.* files to toxav/groupav.*"
mv -v $OUTPUT/toxav/group.h $OUTPUT/toxav/groupav.h
mv -v $OUTPUT/toxav/group.m $OUTPUT/toxav/groupav.m
