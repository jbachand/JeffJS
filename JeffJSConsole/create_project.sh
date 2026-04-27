#!/bin/bash
# Creates the JeffJSConsole Xcode project.
# Usage: cd JeffJSConsole && ./create_project.sh
#
# This creates a multiplatform SwiftUI app that depends on the local JeffJS package.
# After running, open JeffJSConsole.xcodeproj in Xcode.

set -e

echo "To create the Xcode project:"
echo ""
echo "1. Open Xcode"
echo "2. File > New > Project"
echo "3. Select 'App' under Multiplatform"
echo "4. Name: JeffJSConsole"
echo "5. Save in: $(pwd)"
echo "6. Delete the generated ContentView.swift (we have our own)"
echo "7. Add local package: File > Add Package Dependencies > Add Local"
echo "8. Select the JeffJS directory (parent of this directory)"
echo "9. Copy JeffJSConsole/JeffJSConsoleApp.swift and ConsoleView.swift into the project"
echo "10. Build and run!"
echo ""
echo "Alternatively, open the JeffJS Package.swift directly in Xcode to explore the library."
