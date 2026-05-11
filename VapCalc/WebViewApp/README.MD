compile and run with the following commands:
```
clang -fobjc-arc -framework Cocoa -framework WebKit WebViewApp.m -o WebViewApp
```
```
./WebViewApp
```
Having bugs? Open an issue and paste the terminal log + "vapcalcneo" console.app logs from launch to exit in the following format, using 3 backticks around each log:

Title: issue description

Body:
Terminal
```
user@name WebViewApp % clang -fobjc-arc -framework Cocoa -framework WebKit WebViewApp.m -o WebViewApp
<placeholder (1 warning expected)>
user@name WebViewAPP % ./WebViewApp
<placeholder (Include full log until ctrl+C to quit)>
```
console.app
```
<placeholder (Include full log from startup to quit, filtered by "vapcalcneo")>
```
