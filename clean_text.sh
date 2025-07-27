#!/usr/bin/env bash

set -euo pipefail

cleaned=$(
	sed \
		-e 's/\bRISC-V\b/Risc Five/g' \
		-e 's/\bNVIDIA\b/N Vidia/g' \
		-e 's/\bAMD\b/A M D/g' \
		-e 's/\bI\/O\b/I O/g' \
		-e 's/\bAND\b/And/g' \
		-e 's/\bOR\b/Or/g' \
		-e 's/\bXOR\b/X Or/g' \
		-e 's/\bMMU\b/M M U/g' \
		-e 's/\bRISC\b/Risc Architecture/g' \
		-e 's/\bPCIe\b/P C I E/g' \
		-e 's/\bUTF-8\b/U T F eight/g' \
		-e 's/\bUTF-16\b/U T F sixteen/g' \
		-e 's/\bP&L\b/P and L/g' \
		-e 's/\bR&D\b/R and D/g' \
		-e 's/\bCAGR\b/C A G R/g' \
		-e 's/\bOOP\b/O O P/g' \
		-e 's/\bFP\b/F P/g' \
		-e 's/\bCPU\b/C P U/g' \
		-e 's/\bGPU\b/G P U/g' \
		-e 's/\bRAM\b/R A M/g' \
		-e 's/\bROM\b/R O M/g' \
		-e 's/\bSSD\b/S S D/g' \
		-e 's/\bHDD\b/H D D/g' \
		-e 's/\bMBR\b/M B R/g' \
		-e 's/\bGPT\b/G P T/g' \
		-e 's/\bFSB\b/F S B/g' \
		-e 's/\bISA\b/I S A/g' \
		-e 's/\bALU\b/A L U/g' \
		-e 's/\bFPU\b/F P U/g' \
		-e 's/\bTLB\b/T L B/g' \
		-e 's/\bSRAM\b/S R A M/g' \
		-e 's/\bDRAM\b/D Ram/g' \
		-e 's/\bFPGA\b/F P G A/g' \
		-e 's/\bASIC\b/A S I C/g' \
		-e 's/\bSoC\b/S o C/g' \
		-e 's/\bNoC\b/N o C/g' \
		-e 's/\bSIMD\b/S I M D/g' \
		-e 's/\bMIMD\b/M I M D/g' \
		-e 's/\bVLIW\b/V L I W/g' \
		-e 's/\bL1\b/L one/g' \
		-e 's/\bL2\b/L two/g' \
		-e 's/\bL3\b/L three/g' \
		-e 's/\bAPI\b/A P I/g' \
		-e 's/\bSQL\b/S Q L/g' \
		-e 's/\bNoSQL\b/No S Q L/g' \
		-e 's/\bJSON\b/J S O N/g' \
		-e 's/\bXML\b/X M L/g' \
		-e 's/\bHTML\b/H T M L/g' \
		-e 's/\bCSS\b/C S S/g' \
		-e 's/\bJS\b/J S/g' \
		-e 's/\bTS\b/T S/g' \
		-e 's/\bPHP\b/P H P/g' \
		-e 's/\bPY\b/P Y/g' \
		-e 's/\bRB\b/R B/g' \
		-e 's/\bGO\b/G O/g' \
		-e 's/\bRS\b/R S/g' \
		-e 's/\bSH\b/S H/g' \
		-e 's/\bVB\b/V B/g' \
		-e 's/\bOS\b/O S/g' \
		-e 's/\bPOSIX\b/P O S I X/g' \
		-e 's/\bIEEE\b/I triple E/g' \
		-e 's/\bACM\b/A C M/g' \
		-e 's/\bQED\b/Q E D/g' \
		-e 's/\bLHS\b/L H S/g' \
		-e 's/\bRHS\b/R H S/g' \
		-e 's/\bROI\b/R O I/g' \
		-e 's/\bEBITDA\b/E B I T D A/g' \
		-e 's/\bCAPEX\b/C A P E X/g' \
		-e 's/\bOPEX\b/O P E X/g' \
		-e 's/\bNPV\b/N P V/g' \
		-e 's/\bIRR\b/I R R/g' \
		-e 's/\bKPI\b/K P I/g' \
		-e 's/\bSWOT\b/S W O T/g' \
		-e 's/\bB2B\b/B to B/g' \
		-e 's/\bB2C\b/B to C/g' \
		-e 's/\bIPO\b/I P O/g' \
		-e 's/\bM&A\b/M and A/g' \
		-e 's/\b\([0-9]\+\)\s*Hz\b/\1 hertz/g' \
		-e 's/\b\([0-9]\+\)\s*KHz\b/\1 kilohertz/g' \
		-e 's/\b\([0-9]\+\)\s*MHz\b/\1 megahertz/g' \
		-e 's/\b\([0-9]\+\)\s*GHz\b/\1 gigahertz/g' \
		-e 's/\b\([0-9]\+\)\s*THz\b/\1 terahertz/g' \
		-e 's/\b\([0-9]\+\)\s*ms\b/\1 milliseconds/g' \
		-e 's/\b\([0-9]\+\)\s*μs\b/\1 microseconds/g' \
		-e 's/\b\([0-9]\+\)\s*ns\b/\1 nanoseconds/g' \
		-e 's/\b\([0-9]\+\)\s*ps\b/\1 picoseconds/g' \
		-e 's/\b\([0-9]\+\)\s*kg\b/\1 kilogram/g' \
		-e 's/\b\([0-9]\+\)\s*g\b/\1 gram/g' \
		-e 's/\b\([0-9]\+\)\s*N\b/\1 newton/g' \
		-e 's/\b\([0-9]\+\)\s*Pa\b/\1 pascal/g' \
		-e 's/\b\([0-9]\+\)\s*J\b/\1 joule/g' \
		-e 's/\b\([0-9]\+\)\s*K\b/\1 kelvin/g' \
		-e 's/\b\([0-9]\+\)\s*[Cc]oulombs\?\b/\1 coulomb/g' \
		-e 's/\b\([0-9]\+\)\s*V\b/\1 volt/g' \
		-e 's/\b\([0-9]\+\)\s*A\b/\1 ampere/g' \
		-e 's/\b\([0-9]\+\)\s*W\b/\1 watt/g' \
		-e 's/\b\([0-9]\+\)\s*Ω\b/\1 ohm/g' \
		-e 's/\b\([0-9]\+\)\s*F\b/\1 farad/g' \
		-e 's/\b\([0-9]\+\)\s*T\b/\1 tesla/g' \
		-e 's/\b\([0-9]\+\)\s*S\b/\1 siemens/g' \
		-e 's/\b\([0-9]\+\)\s*H\b/\1 henry/g' \
		-e 's/\b\([0-9]\+\)\s*mol\b/\1 mole/g' \
		-e 's/\b\([0-9]\+\)\s*L\b/\1 liter/g' \
		-e 's/\b\([0-9]\+\)\s*ml\b/\1 milliliter/g' \
		-e 's/\b\([0-9]\+\)\s*cm\b/\1 centimeter/g' \
		-e 's/\b\([0-9]\+\)\s*mm\b/\1 millimeter/g' \
		-e 's/\b\([0-9]\+\)\s*μm\b/\1 micron/g' \
		-e 's/\b\([0-9]\+\)\s*nm\b/\1 nanometer/g' \
		-e 's/\b\([0-9]\+\)\s*pm\b/\1 picometer/g' \
		-e 's/\([a-zA-Z_][a-zA-Z0-9_]*\)\[\([^]]*\)\]/\1 array index \2/g' \
		-e 's/\([a-zA-Z_][a-zA-Z0-9_]*\)++/increment \1 by one/g' \
		-e 's/++\([a-zA-Z_][a-zA-Z0-9_]*\)/increment \1 by one/g' \
		-e 's/\([a-zA-Z_][a-zA-Z0-9_]*\)--/decrement \1 by one/g' \
		-e 's/--\([a-zA-Z_][a-zA-Z0-9_]*\)/decrement \1 by one/g' \
		-e 's/\([a-zA-Z_][a-zA-Z0-9_]*\) += *\([^;,)]*\)/increment \1 by \2/g' \
		-e 's/\([a-zA-Z_][a-zA-Z0-9_]*\) -= *\([^;,)]*\)/decrement \1 by \2/g' \
		-e 's/&&/ and and /g' \
		-e 's/||/ or or /g' \
		-e 's/&/ and /g' \
		-e 's/|/ or /g' \
		-e 's/</ less than /g' \
		-e 's/>/ greater than /g' \
		-e 's/==/ is equal to /g' \
		-e 's/=/ is /g' \
		-e 's/—/, /g' \
		-e 's/;/, /g' \
		-e 's/ - / minus /g' \
		-e 's/-/ /g' \
		-e 's/`//g' \
		-e 's/\([a-zA-Z0-9_)]\) \* \([a-zA-Z0-9_(]\)/ \1 times \2 /g' \
		-e 's/\([a-zA-Z0-9_)]\)\*\([a-zA-Z0-9_(]\)/ \1 times \2 /g' \
		-e 's/\*//g' \
		-e 's/[#_;\[\]{}<>"]/ /g' \
		-e 's/  */ /g' \
		-e 's/+/ plus /g' \
		-e 's/\n\n\n*/\n\n/g'
)

echo "$cleaned" | awk '
function num2word(x) {
  return
         (x == "32") ? "thirty two" :
         (x == "64") ? "sixty four" :
         (x == "128") ? "one hundred twenty eight" : x
}
function hex2word(x) {
  return (x == "a" || x == "A") ? "A" :
         (x == "b" || x == "B") ? "B" :
         (x == "c" || x == "C") ? "C" :
         (x == "d" || x == "D") ? "D" :
         (x == "e" || x == "E") ? "E" :
         (x == "f" || x == "F") ? "F" : num2word(x)
}
{
  n=split($0, words, /[ \t]+/)
  for (i=1; i<=n; ++i) {
    word = words[i]
    if (word ~ /^-0x[0-9a-fA-F]+$/) {
      printf "minus hexadecimal "
      hex = substr(word, 4)
      for (j = 1; j <= length(hex); j++) printf "%s ", hex2word(substr(hex, j, 1))
    }
    else if (word ~ /^-0b[01]+$/) {
      printf "minus binary "
      bin = substr(word, 4)
      for (j = 1; j <= length(bin); j++) printf "%s ", (substr(bin, j, 1) == "1") ? "one" : "zero"
    }
    else if (word ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) {
      if (word ~ /^-/) {
        printf "minus "
        word = substr(word, 2)
      }
      nE = split(word, arr, /[eE]/)
      if (nE==2) {
        mant = arr[1]; expo = arr[2]
        if (index(mant, ".")) {
          split(mant, arr2, /\./)
          for (j=1; j<=length(arr2[1]); j++) printf "%s ", num2word(substr(arr2[1], j, 1))
          printf "point "
          for (j=1; j<=length(arr2[2]); j++) printf "%s ", num2word(substr(arr2[2], j, 1))
        } else {
          for (j=1; j<=length(mant); j++) printf "%s ", num2word(substr(mant, j, 1))
        }
        printf "times ten to the power of "
        if (expo ~ /^-/) { printf "minus "; expo=substr(expo,2)}
        if (expo ~ /^\+/) {expo=substr(expo,2)}
        for (j=1;j<=length(expo);j++) printf "%s ", num2word(substr(expo, j, 1))
      } else if (index(word, ".")) {
        split(word, arr2, /\./)
        for (j=1;j<=length(arr2[1]);j++) printf "%s ", num2word(substr(arr2[1], j, 1))
        printf "point "
        for (j=1;j<=length(arr2[2]);j++) printf "%s ", num2word(substr(arr2[2], j, 1))
      } else {
        for (j=1;j<=length(word);j++) printf "%s ", num2word(substr(word, j, 1))
      }
    }
    else if (word ~ /^0x[0-9a-fA-F]+$/) {
      printf "hexadecimal "
      hex = substr(word, 3)
      for (j = 1; j <= length(hex); j++) printf "%s ", hex2word(substr(hex, j, 1))
    }
    else if (word ~ /^0b[01]+$/) {
      printf "binary "
      bin = substr(word, 3)
      for (j = 1; j <= length(bin); j++) printf "%s ", (substr(bin, j, 1) == "1") ? "one" : "zero"
    }
    else if (word ~ /^[01]+$/ && length(word) > 4) {
      for (j = 1; j <= length(word); j++) printf "%s ", (substr(word, j, 1) == "1") ? "one" : "zero"
    }
    else if (word ~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/) {
      gsub(/\./, " dot ", word)
      printf "%s ", word
    }
    else if (word ~ /^[0-9]+(\.[0-9]+)+$/) {
      gsub(/\./, " point ", word)
      printf "%s ", word
    }
    else if (word ~ /^[a-zA-Z][a-zA-Z0-9]*[A-Z][a-zA-Z0-9]*$/) {
      result=""
      for (j = 1; j <= length(word); j++) {
        char = substr(word, j, 1)
        if (j > 1 && char ~ /[A-Z]/ && substr(word, j-1, 1) ~ /[a-z0-9]/) {
          result = result " " tolower(char)
        } else {
          result = result tolower(char)
        }
      }
      printf "%s ", result
    }
    else {
      printf "%s ", word
    }
  }
  printf "\n"
}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/  */ /g' | awk '
BEGIN { blank_lines = 0 }
/^[[:space:]]*$/ { 
  blank_lines++
  if (blank_lines <= 1) print
  next
}
{ blank_lines = 0; print }
'
