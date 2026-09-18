#!/bin/bash
# This project automatically creates layouts for projects depedning on type

PROJECT_NAME="$1"
PROJECT_TYPE="$2"
DESC="$3"
NAME="Daniel Huynh"


echo "Initializing setup for: $PROJECT_NAME of type: $PROJECT_TYPE"

setup_README(){
    
    # Create a README.md file with the project name and type
    cat <<EOF > README.md
# $NAME, $PROJECT_NAME, $(date)
# $DESC 

EOF

}

setup_cpp() {
    # C++ setup
    mkdir src include tests docs

    touch include/$PROJECT_NAME.h 
    touch tests/test.cpp 
    touch README.md
    cat <<EOF > src/$PROJECT_NAME.cpp
    #include "include/$PROJECT_NAME.h"

    int main() {
        // Your code here
        return 0;
    }
EOF
    cat <<EOF > include/$PROJECT_NAME.h
    #include <iostream>

    using namespace std;
EOF


}



case "$PROJECT_TYPE" in
    cpp)
        setup_cpp
        setup_README
        ;;
    *)
        echo "Unknown project type: $PROJECT_TYPE"
        exit 1
        ;;
esac
