// Decompiles a list of functions of the current Ghidra program, one C file per
// function.
//
// Purpose: REA's CLI decompiles one procedure per run and re-runs Ghidra's full
// analysis of Dock each time (about 3 minutes). Reverse engineering a whole
// subsystem needs hundreds of methods, so this script runs inside Ghidra's
// headless analyzer against a project that was analyzed once and saved.
//
// Usage (GHIDRA_INSTALL_DIR and JAVA_HOME exported):
//   first run, imports and analyzes the binary and saves the project:
//     $GHIDRA_INSTALL_DIR/support/analyzeHeadless <project dir> <project name> \
//       -import <thin Mach-O> -scriptPath tools/re/ghidra \
//       -postScript DecompileList.java <list file> <output dir>
//   later runs reuse the saved analysis:
//     $GHIDRA_INSTALL_DIR/support/analyzeHeadless <project dir> <project name> \
//       -process <binary file name> -noanalysis -scriptPath tools/re/ghidra \
//       -postScript DecompileList.java <list file> <output dir>
//
// The list file has one function per line: an address (0x...) and a name used
// for the output file, separated by a space, for example
//   0x100008E80 -[Springboard _setupApplicationSources:]
// Lines that are empty or start with '#' are skipped. A function is created at
// an address that has none.
//
// Output: <output dir>/<name with every character outside [A-Za-z0-9_.+-]
// replaced by '_'>.c, starting with a comment line that holds the name and the
// address. A function that fails to decompile gets a .err file with the reason.
// Keep the project, the lists and the output under research/ (clean room).

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;

public class DecompileList extends GhidraScript {

	@Override
	public void run() throws Exception {
		String[] args = getScriptArgs();
		if (args.length != 2) {
			printerr("usage: DecompileList.java <list file> <output dir>");
			return;
		}
		List<String> lines = Files.readAllLines(Paths.get(args[0]), StandardCharsets.UTF_8);
		Path outDir = Paths.get(args[1]);
		Files.createDirectories(outDir);

		DecompInterface decompiler = new DecompInterface();
		decompiler.setOptions(new DecompileOptions());
		decompiler.toggleCCode(true);
		decompiler.toggleSyntaxTree(true);
		decompiler.setSimplificationStyle("decompile");
		if (!decompiler.openProgram(currentProgram)) {
			printerr("decompiler did not open the program: " + decompiler.getLastMessage());
			return;
		}

		int done = 0;
		int failed = 0;
		for (String raw : lines) {
			String line = raw.trim();
			if (line.isEmpty() || line.startsWith("#")) {
				continue;
			}
			int space = line.indexOf(' ');
			String addressText = space < 0 ? line : line.substring(0, space);
			String name = space < 0 ? addressText : line.substring(space + 1).trim();
			String fileName = name.replaceAll("[^A-Za-z0-9_.+-]", "_");

			Address address = toAddr(addressText);
			Function function = getFunctionAt(address);
			if (function == null) {
				function = createFunction(address, null);
			}
			if (function == null) {
				Files.writeString(outDir.resolve(fileName + ".err"), "no function at " + addressText + "\n");
				failed++;
				continue;
			}
			DecompileResults results = decompiler.decompileFunction(function, 120, monitor);
			if (!results.decompileCompleted()) {
				Files.writeString(outDir.resolve(fileName + ".err"), results.getErrorMessage() + "\n");
				failed++;
				continue;
			}
			String code = "// " + name + " " + addressText + "\n" + results.getDecompiledFunction().getC();
			Files.writeString(outDir.resolve(fileName + ".c"), code);
			done++;
		}
		decompiler.dispose();
		println("decompiled " + done + ", failed " + failed);
	}
}
