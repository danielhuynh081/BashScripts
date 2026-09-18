#!/bin/bash
# This project automatically creates layouts for projects depending on type

PROJECT_NAME="$1"
PROJECT_TYPE="$2"
DESC="$3"
NAME="Daniel Huynh"

echo "Initializing setup for: $PROJECT_NAME of type: $PROJECT_TYPE"

setup_README() {
    cat <<EOF > README.md
# $NAME - $PROJECT_NAME
Created: $(date)

$DESC
EOF
}

setup_cpp() {
    setup_README

    mkdir -p src include tests docs

    touch "include/$PROJECT_NAME.h"
    touch "tests/test.cpp"

    cat <<EOF > "src/$PROJECT_NAME.cpp"
#include "../include/$PROJECT_NAME.h"

int main() {
    // Your code here
    return 0;
}
EOF

    cat <<EOF > "include/$PROJECT_NAME.h"
#ifndef ${PROJECT_NAME^^}_H
#define ${PROJECT_NAME^^}_H

#include <iostream>

using namespace std;

#endif
EOF
}

setup_vite() {
    npm create vite@latest "$PROJECT_NAME" -- --template react
    cd "$PROJECT_NAME" || exit 1
    npm install
    setup_README
}

setup_typescript() {
    npm create vite@latest "$PROJECT_NAME" -- --template react-ts
    cd "$PROJECT_NAME" || exit 1
    npm install
    setup_README
}

setup_nextjs() {
    npx create-next-app@latest "$PROJECT_NAME"
}

setup_react() {
    npx create-react-app "$PROJECT_NAME"
}

setup_vite_tailwind() {
    npm create vite@latest "$PROJECT_NAME" -- --template react
    cd "$PROJECT_NAME" || exit 1

    npm install
    npm install tailwindcss @tailwindcss/vite

    setup_README
}

setup_default() {
    setup_README

    mkdir -p src tests public scripts docs

    touch .env
    touch .gitignore
}

case "$PROJECT_TYPE" in
    cpp)
        setup_cpp
        ;;
    vite)
        setup_vite
        ;;
    typescript)
        setup_typescript
        ;;
    nextjs)
        setup_nextjs
        ;;
    react)
        setup_react
        ;;
    vite-tailwind)
        setup_vite_tailwind
        ;;
    *)
        echo "Unknown project type: $PROJECT_TYPE"
        setup_default
        ;;
esac