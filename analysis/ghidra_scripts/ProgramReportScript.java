import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Program;
import ghidra.program.model.mem.MemoryBlock;

public class ProgramReportScript extends GhidraScript {
    @Override
    protected void run() throws Exception {
        Program program = currentProgram;

        println("PROGRAM_REPORT_BEGIN");
        println("PROGRAM_NAME=" + program.getName());
        println("EXEC_FORMAT=" + program.getExecutableFormat());
        println("LANGUAGE_ID=" + program.getLanguage().getLanguageID());
        println("COMPILER_SPEC_ID=" + program.getCompilerSpec().getCompilerSpecID());
        println("IMAGE_BASE=" + program.getImageBase());
        println("MIN_ADDRESS=" + program.getMinAddress());
        println("MAX_ADDRESS=" + program.getMaxAddress());
        println("FUNCTION_COUNT=" + program.getFunctionManager().getFunctionCount());
        println("MEMORY_BLOCKS_BEGIN");
        for (MemoryBlock block : program.getMemory().getBlocks()) {
            println(String.format(
                "BLOCK name=%s start=%s end=%s size=0x%x r=%s w=%s x=%s init=%s overlay=%s",
                block.getName(),
                block.getStart(),
                block.getEnd(),
                block.getSize(),
                block.isRead(),
                block.isWrite(),
                block.isExecute(),
                block.isInitialized(),
                block.isOverlay()
            ));
        }
        println("MEMORY_BLOCKS_END");
        println("PROGRAM_REPORT_END");
    }
}
