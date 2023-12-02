JetBrains doesn't provide a robust, easy-to-use macOS command-line interface for [IntelliJ IDEA](https://www.jetbrains.com/idea/)
and its related IDEs (which are otherwise excellent tools).

Sure, [Toolbox](https://www.jetbrains.com/toolbox-app/) creates wrapper scripts, but they're very minimal, 
and don't make it clear what commands or options are available.
A couple of additional wrapper scripts are provided inside the app bundle, for formatting and inspecting code, 
but again they're very minimal and not self-documenting at all. And there are no man pages. So you pretty much have to 
track down the [online documentation](https://www.jetbrains.com/help/idea/working-with-the-ide-features-from-command-line.html),
and scan through it for info any time you want to invoke an IDE from the terminal.

**_What if we tried to fix all that?_**
