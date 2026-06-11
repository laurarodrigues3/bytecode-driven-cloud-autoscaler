package pt.ulisboa.tecnico.cnv.javassist;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import java.util.Arrays;

import javassist.ClassPool;
import javassist.CtClass;
import javassist.CtMethod;
import javassist.bytecode.BadBytecode;
import javassist.bytecode.Bytecode;
import javassist.bytecode.CodeAttribute;
import javassist.bytecode.CodeIterator;
import javassist.bytecode.MethodInfo;
import javassist.bytecode.analysis.ControlFlow;
import javassist.bytecode.analysis.ControlFlow.Block;

import java.util.HashMap;
import java.util.Map;

/**
 * Javassist-based Java agent that instruments workload classes at load time
 * to collect dynamic execution metrics.
 *
 * <p><b>Primary metric: instruction count (ICount).</b> Using {@link ControlFlow}
 * we identify the basic blocks of every method and, at the entry of each block,
 * inject {@code MetricRegistry.incrementInstructions(N)} where {@code N} is the
 * number of bytecode instructions contained in that block. The accumulated
 * counter scales with the actual work executed (each loop iteration enters its
 * body block once, contributing its instruction count) and is the metric used
 * by the load balancer / auto-scaler to estimate request complexity.
 *
 * <p><b>Secondary metric: method-call count.</b> A single increment is injected
 * at the entry of every instrumented method. Used as a cross-check signal
 * (e.g.&nbsp;to detect anomalies in DNA where method invocations dominate the
 * inner loop).
 *
 * <p>Only classes in {@link #TARGET_PACKAGES} are instrumented — JDK and
 * webserver framework code are deliberately left out (overhead vs. usefulness
 * trade-off, see project FAQ).
 */
public class JavassistAgent {

    /** Packages whose classes will be instrumented. */
    private static final String[] TARGET_PACKAGES = {
            "pt.ulisboa.tecnico.cnv.fractals",
            "pt.ulisboa.tecnico.cnv.grayscott",
            "pt.ulisboa.tecnico.cnv.dna"
    };

    /** Handler classes where request start/stop is injected. */
    private static final String[] HANDLER_CLASSES = {
            "pt.ulisboa.tecnico.cnv.fractals.FractalsHandler",
            "pt.ulisboa.tecnico.cnv.grayscott.GrayScottHandler",
            "pt.ulisboa.tecnico.cnv.dna.DnaHandler"
    };

    /** Internal (slash-separated) name of MetricRegistry, used in invokestatic. */
    private static final String METRIC_REGISTRY_INTERNAL =
            "pt/ulisboa/tecnico/cnv/javassist/MetricRegistry";

    public static void premain(String args, Instrumentation inst) {
        System.out.println("[JavassistAgent] Agent loaded. Instrumenting workload classes...");
        inst.addTransformer(new CNVTransformer());
    }

    /**
     * ClassFileTransformer that uses Javassist to inject metric-collection code.
     */
    static class CNVTransformer implements ClassFileTransformer {

        @Override
        public byte[] transform(ClassLoader loader, String className,
                                Class<?> classBeingRedefined,
                                ProtectionDomain protectionDomain,
                                byte[] classfileBuffer) {
            if (className == null) return null;

            String dotName = className.replace('/', '.');

            // Only instrument our target packages.
            boolean isTarget = false;
            for (String pkg : TARGET_PACKAGES) {
                if (dotName.startsWith(pkg)) {
                    isTarget = true;
                    break;
                }
            }
            if (!isTarget) return null;

            try {
                ClassPool pool = ClassPool.getDefault();
                CtClass cc = pool.get(dotName);

                if (cc.isFrozen()) {
                    cc.defrost();
                }

                boolean isHandler = false;
                for (String h : HANDLER_CLASSES) {
                    if (dotName.equals(h)) {
                        isHandler = true;
                        break;
                    }
                }

                int totalBlocks = 0;
                long totalInstructions = 0;
                for (CtMethod method : cc.getDeclaredMethods()) {
                    if (method.isEmpty()) continue;

                    // 1) Per-basic-block instruction counters (uses ORIGINAL bytecode
                    //    offsets). Must run before any insertBefore/insertAfter, which
                    //    would shift offsets and invalidate the ControlFlow positions.
                    InstrumentationStats stats = instrumentBasicBlocks(method);
                    totalBlocks += stats.blocks;
                    totalInstructions += stats.instructions;

                    // 2) Per-method-call counter at method entry (secondary metric).
                    method.insertBefore(
                            "{ pt.ulisboa.tecnico.cnv.javassist.MetricRegistry.incrementMethodCalls(); }");

                    // 3) For handler classes, wrap handle(HttpExchange) with
                    //    startRequest/stopRequest.
                    if (isHandler && method.getName().equals("handle")
                            && method.getParameterTypes().length == 1) {
                        instrumentHandleMethod(method, dotName);
                    }
                }

                byte[] bytecode = cc.toBytecode();
                cc.detach();
                System.out.println("[JavassistAgent] Instrumented: " + dotName
                        + " (" + totalBlocks + " blocks, " + totalInstructions + " static instructions)");
                return bytecode;

            } catch (Exception e) {
                System.err.println("[JavassistAgent] Failed to instrument " + dotName + ": " + e.getMessage());
                return null;
            }
        }

        /**
         * Wraps the handle() method with startRequest/stopRequest calls.
         */
        private void instrumentHandleMethod(CtMethod method, String className) throws Exception {
            // Build a request ID from query string for tracing.
            String startCode =
                    "{ " +
                    "  String __uri = $1.getRequestURI().toString(); " +
                    "  pt.ulisboa.tecnico.cnv.javassist.MetricRegistry.startRequest(__uri); " +
                    "}";
            method.insertBefore(startCode);

            String stopCode =
                    "{ pt.ulisboa.tecnico.cnv.javassist.MetricRegistry.stopRequest(); }";
            method.insertAfter(stopCode, /* asFinally */ true);
        }

        /** Internal carrier for the (blocks, instructions) tuple produced per method. */
        private static final class InstrumentationStats {
            final int blocks;
            final long instructions;
            InstrumentationStats(int blocks, long instructions) {
                this.blocks = blocks;
                this.instructions = instructions;
            }
            static final InstrumentationStats EMPTY = new InstrumentationStats(0, 0L);
        }

        /**
         * Inserts {@code MetricRegistry.incrementInstructions(N)} at the entry of
         * every basic block of {@code method}, where {@code N} is the number of
         * bytecode instructions in that block. Uses {@link ControlFlow} analysis
         * to identify true basic-block boundaries.
         *
         * <p>This is the canonical <b>ICount</b> instrumentation: at runtime the
         * counter accumulates the total number of instructions executed inside
         * the workload code, scaled by the dynamic visit count of each block.
         *
         * <p>Implementation notes:
         * <ul>
         *   <li>Phase 1 walks the bytecode to count instructions per block using
         *       the <b>original</b> {@link CodeAttribute}. This must happen before
         *       any byte injection so that block positions remain valid.</li>
         *   <li>Phase 2 injects payloads in <b>descending position order</b> so
         *       that the original offsets reported by ControlFlow remain valid
         *       for the still-unprocessed (lower-offset) blocks.</li>
         *   <li>{@link CodeIterator#insertAt(int, byte[])} updates branch offsets
         *       and exception-handler ranges automatically.</li>
         *   <li>After all insertions the stack-map table is rebuilt
         *       ({@code rebuildStackMapIf6}); without it Java 7+ class files
         *       would be rejected by the verifier.</li>
         * </ul>
         */
        private InstrumentationStats instrumentBasicBlocks(CtMethod method) throws Exception {
            MethodInfo methodInfo = method.getMethodInfo();
            CodeAttribute codeAttribute = methodInfo.getCodeAttribute();
            if (codeAttribute == null) return InstrumentationStats.EMPTY;

            Block[] blocks;
            try {
                ControlFlow cf = new ControlFlow(method.getDeclaringClass(), methodInfo);
                blocks = cf.basicBlocks();
            } catch (Exception e) {
                // Some pathological methods can't be analysed; skip them gracefully.
                System.err.println("[JavassistAgent] ControlFlow failed for "
                        + method.getLongName() + ": " + e.getMessage());
                return InstrumentationStats.EMPTY;
            }
            if (blocks == null || blocks.length == 0) return InstrumentationStats.EMPTY;

            // Phase 1: count instructions per block on the ORIGINAL bytecode.
            Map<Block, Integer> instructionsPerBlock = new HashMap<>();
            long totalInstructions = 0;
            for (Block b : blocks) {
                int n = countInstructionsInBlock(codeAttribute, b.position(), b.length());
                instructionsPerBlock.put(b, n);
                totalInstructions += n;
            }

            // Phase 2: inject in descending position order so original offsets stay valid
            //          for the blocks still to be processed.
            Block[] sorted = blocks.clone();
            Arrays.sort(sorted, (a, b) -> Integer.compare(b.position(), a.position()));

            CodeIterator ci = codeAttribute.iterator();
            for (Block b : sorted) {
                int n = instructionsPerBlock.get(b);
                if (n <= 0) continue; // defensively skip zero-length blocks
                // Build payload: ldc2_w/lconst N; invokestatic MetricRegistry.incrementInstructions(J)V
                // Stack effect: +2 then -2 (long is 2 slots, consumed by invoke).
                Bytecode bc = new Bytecode(methodInfo.getConstPool());
                bc.addLconst((long) n);
                bc.addInvokestatic(METRIC_REGISTRY_INTERNAL,
                        "incrementInstructions", "(J)V");
                ci.insertAt(b.position(), bc.get());
            }

            // Recompute max stack and rebuild stack-map for Java 6/7+ class files.
            codeAttribute.computeMaxStack();
            methodInfo.rebuildStackMapIf6(
                    method.getDeclaringClass().getClassPool(),
                    method.getDeclaringClass().getClassFile2());

            return new InstrumentationStats(blocks.length, totalInstructions);
        }

        /**
         * Counts the number of bytecode instructions inside {@code [start, start+length)}
         * by walking the (original) bytecode with a fresh {@link CodeIterator}.
         *
         * @return number of instructions in the range; minimum 1 to avoid zero counters.
         */
        private int countInstructionsInBlock(CodeAttribute codeAttribute, int start, int length)
                throws BadBytecode {
            if (length <= 0) return 1;
            int end = start + length;
            int count = 0;
            CodeIterator ci = codeAttribute.iterator();
            ci.move(start);
            while (ci.hasNext()) {
                int pos = ci.next();
                if (pos >= end) break;
                count++;
            }
            return Math.max(1, count);
        }
    }
}
