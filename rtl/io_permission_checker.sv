// Brendan Lynskey 2025
module io_permission_checker
    import iommu_pkg::*;
(
    input  device_context_t             ctx,
    input  logic                        is_read,
    input  logic                        is_write,

    output logic                        ctx_valid,
    output logic                        ctx_fault,
    output logic [3:0]                  ctx_fault_cause,
    output logic                        needs_translation
);

    always @(*) begin
        ctx_valid       = 1'b0;
        ctx_fault       = 1'b0;
        ctx_fault_cause = CAUSE_NONE;
        needs_translation = 1'b0;

        if (!ctx.en) begin
            // Device context disabled
            ctx_fault       = 1'b1;
            ctx_fault_cause = CAUSE_CTX_INVALID;
        end else if (is_read && !ctx.rp) begin
            // Read not permitted
            ctx_fault       = 1'b1;
            ctx_fault_cause = CAUSE_CTX_READ_DENIED;
        end else if (is_write && !ctx.wp) begin
            // Write not permitted
            ctx_fault       = 1'b1;
            ctx_fault_cause = CAUSE_CTX_WRITE_DENIED;
        end else if (ctx.mode == MODE_BARE) begin
            // Bare/passthrough mode -- no translation needed
            ctx_valid         = 1'b1;
            needs_translation = 1'b0;
        end else if (ctx.mode == MODE_SV32) begin
            // Sv32 single-stage translation
            ctx_valid         = 1'b1;
            needs_translation = 1'b1;
        end else begin
            // Invalid/unsupported mode
            ctx_fault       = 1'b1;
            ctx_fault_cause = CAUSE_CTX_INVALID;
        end
    end

endmodule
