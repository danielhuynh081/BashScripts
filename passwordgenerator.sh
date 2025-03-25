#!/bin/bash
# This is a simple password generator
# Password will be 8 characters long
# Password will have to include numbers, letters, and special characters

# A random number as a seed
RANDOM=$$$(date +%s)

# Define the length of the password
LENGTH=8

# Define the characters that can be used in the password
CHARACTERS="!@#$%^&*()_-+={}[]|:;'<>,.?/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

# Generate the password
for i in $(seq 1 $LENGTH)
do
    # Get a random number between 1 and the length of the character list
    CHAR=$(($RANDOM % ${#CHARACTERS}))
    # Append the random character to the password
    PASSWORD="${PASSWORD}${CHARACTERS:$CHAR:1}"
done

# Output the password
echo $PASSWORD

# End of script

# Run the script
# $ ./passwordgenerator.sh
# Output: 1@7|+7^7
