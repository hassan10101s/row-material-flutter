package android.print;

/**
 * Android's SDK gives the print callbacks package-private constructors.
 * Keep the small public constructor bridge in their package, without reflection.
 */
public final class MaterialLabPdfCallbacks {
    private MaterialLabPdfCallbacks() {}

    public abstract static class Layout extends PrintDocumentAdapter.LayoutResultCallback {
        public Layout() { super(); }
    }

    public abstract static class Write extends PrintDocumentAdapter.WriteResultCallback {
        public Write() { super(); }
    }
}
