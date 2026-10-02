@C
func __cjbind_read_VArray<drwav_uint8_drwav_uint8,$4>(ptr: CPointer<UInt8>): VArray<drwav_uint8_drwav_uint8, $4> {
    return unsafe { CPointer<VArray<drwav_uint8_drwav_uint8, $4>>(ptr).read() }
}

@C
func __cjbind_write_VArray<drwav_uint8_drwav_uint8,$4>(ptr: CPointer<UInt8>, val: VArray<drwav_uint8_drwav_uint8, $4>): Unit {
    unsafe { CPointer<VArray<drwav_uint8_drwav_uint8, $4>>(ptr).write(val) }
}

@C
func __cjbind_read_VArray<drwav_uint8_drwav_uint8,$16>(ptr: CPointer<UInt8>): VArray<drwav_uint8_drwav_uint8, $16> {
    return unsafe { CPointer<VArray<drwav_uint8_drwav_uint8, $16>>(ptr).read() }
}

@C
func __cjbind_write_VArray<drwav_uint8_drwav_uint8,$16>(ptr: CPointer<UInt8>, val: VArray<drwav_uint8_drwav_uint8, $16>): Unit {
    unsafe { CPointer<VArray<drwav_uint8_drwav_uint8, $16>>(ptr).write(val) }
}

@C
func __cjbind_read_drwav_cue_drwav_cue(ptr: CPointer<UInt8>): drwav_cue_drwav_cue {
    return unsafe { CPointer<drwav_cue_drwav_cue>(ptr).read() }
}

@C
func __cjbind_write_drwav_cue_drwav_cue(ptr: CPointer<UInt8>, val: drwav_cue_drwav_cue): Unit {
    unsafe { CPointer<drwav_cue_drwav_cue>(ptr).write(val) }
}

@C
func __cjbind_read_drwav_smpl_drwav_smpl(ptr: CPointer<UInt8>): drwav_smpl_drwav_smpl {
    return unsafe { CPointer<drwav_smpl_drwav_smpl>(ptr).read() }
}

@C
func __cjbind_write_drwav_smpl_drwav_smpl(ptr: CPointer<UInt8>, val: drwav_smpl_drwav_smpl): Unit {
    unsafe { CPointer<drwav_smpl_drwav_smpl>(ptr).write(val) }
}

@C
func __cjbind_read_drwav_acid_drwav_acid(ptr: CPointer<UInt8>): drwav_acid_drwav_acid {
    return unsafe { CPointer<drwav_acid_drwav_acid>(ptr).read() }
}

@C
func __cjbind_write_drwav_acid_drwav_acid(ptr: CPointer<UInt8>, val: drwav_acid_drwav_acid): Unit {
    unsafe { CPointer<drwav_acid_drwav_acid>(ptr).write(val) }
}

@C
func __cjbind_read_drwav_inst_drwav_inst(ptr: CPointer<UInt8>): drwav_inst_drwav_inst {
    return unsafe { CPointer<drwav_inst_drwav_inst>(ptr).read() }
}

@C
func __cjbind_write_drwav_inst_drwav_inst(ptr: CPointer<UInt8>, val: drwav_inst_drwav_inst): Unit {
    unsafe { CPointer<drwav_inst_drwav_inst>(ptr).write(val) }
}

@C
func __cjbind_read_drwav_bext_drwav_bext(ptr: CPointer<UInt8>): drwav_bext_drwav_bext {
    return unsafe { CPointer<drwav_bext_drwav_bext>(ptr).read() }
}

@C
func __cjbind_write_drwav_bext_drwav_bext(ptr: CPointer<UInt8>, val: drwav_bext_drwav_bext): Unit {
    unsafe { CPointer<drwav_bext_drwav_bext>(ptr).write(val) }
}

@C
func __cjbind_read_drwav_list_label_or_note_drwav_list_label_or_note(ptr: CPointer<UInt8>): drwav_list_label_or_note_drwav_list_label_or_note {
    return unsafe { CPointer<drwav_list_label_or_note_drwav_list_label_or_note>(ptr).read() }
}

@C
func __cjbind_write_drwav_list_label_or_note_drwav_list_label_or_note(ptr: CPointer<UInt8>, val: drwav_list_label_or_note_drwav_list_label_or_note): Unit {
    unsafe { CPointer<drwav_list_label_or_note_drwav_list_label_or_note>(ptr).write(val) }
}

@C
func __cjbind_read_drwav_list_labelled_cue_region_drwav_list_labelled_cue_region(ptr: CPointer<UInt8>): drwav_list_labelled_cue_region_drwav_list_labelled_cue_region {
    return unsafe { CPointer<drwav_list_labelled_cue_region_drwav_list_labelled_cue_region>(ptr).read() }
}

@C
func __cjbind_write_drwav_list_labelled_cue_region_drwav_list_labelled_cue_region(ptr: CPointer<UInt8>, val: drwav_list_labelled_cue_region_drwav_list_labelled_cue_region): Unit {
    unsafe { CPointer<drwav_list_labelled_cue_region_drwav_list_labelled_cue_region>(ptr).write(val) }
}

@C
func __cjbind_read_drwav_list_info_text_drwav_list_info_text(ptr: CPointer<UInt8>): drwav_list_info_text_drwav_list_info_text {
    return unsafe { CPointer<drwav_list_info_text_drwav_list_info_text>(ptr).read() }
}

@C
func __cjbind_write_drwav_list_info_text_drwav_list_info_text(ptr: CPointer<UInt8>, val: drwav_list_info_text_drwav_list_info_text): Unit {
    unsafe { CPointer<drwav_list_info_text_drwav_list_info_text>(ptr).write(val) }
}

@C
func __cjbind_read_drwav_unknown_metadata_drwav_unknown_metadata(ptr: CPointer<UInt8>): drwav_unknown_metadata_drwav_unknown_metadata {
    return unsafe { CPointer<drwav_unknown_metadata_drwav_unknown_metadata>(ptr).read() }
}

@C
func __cjbind_write_drwav_unknown_metadata_drwav_unknown_metadata(ptr: CPointer<UInt8>, val: drwav_unknown_metadata_drwav_unknown_metadata): Unit {
    unsafe { CPointer<drwav_unknown_metadata_drwav_unknown_metadata>(ptr).write(val) }
}

package m0poc.drlibs

public const DRWAV_VERSION_MAJOR_DRWAV_VERSION_MAJOR : Int8 = 0

public const DRWAV_VERSION_MINOR_DRWAV_VERSION_MINOR : Int8 = 14

public const DRWAV_VERSION_REVISION_DRWAV_VERSION_REVISION : Int8 = 6

public const DRWAV_TRUE_DRWAV_TRUE : Int8 = 1

public const DRWAV_FALSE_DRWAV_FALSE : Int8 = 0

public const DRWAV_SUCCESS_DRWAV_SUCCESS : Int8 = 0

public const DRWAV_ERROR_DRWAV_ERROR : Int8 = -1

public const DRWAV_INVALID_ARGS_DRWAV_INVALID_ARGS : Int8 = -2

public const DRWAV_INVALID_OPERATION_DRWAV_INVALID_OPERATION : Int8 = -3

public const DRWAV_OUT_OF_MEMORY_DRWAV_OUT_OF_MEMORY : Int8 = -4

public const DRWAV_OUT_OF_RANGE_DRWAV_OUT_OF_RANGE : Int8 = -5

public const DRWAV_ACCESS_DENIED_DRWAV_ACCESS_DENIED : Int8 = -6

public const DRWAV_DOES_NOT_EXIST_DRWAV_DOES_NOT_EXIST : Int8 = -7

public const DRWAV_ALREADY_EXISTS_DRWAV_ALREADY_EXISTS : Int8 = -8

public const DRWAV_TOO_MANY_OPEN_FILES_DRWAV_TOO_MANY_OPEN_FILES : Int8 = -9

public const DRWAV_INVALID_FILE_DRWAV_INVALID_FILE : Int8 = -10

public const DRWAV_TOO_BIG_DRWAV_TOO_BIG : Int8 = -11

public const DRWAV_PATH_TOO_LONG_DRWAV_PATH_TOO_LONG : Int8 = -12

public const DRWAV_NAME_TOO_LONG_DRWAV_NAME_TOO_LONG : Int8 = -13

public const DRWAV_NOT_DIRECTORY_DRWAV_NOT_DIRECTORY : Int8 = -14

public const DRWAV_IS_DIRECTORY_DRWAV_IS_DIRECTORY : Int8 = -15

public const DRWAV_DIRECTORY_NOT_EMPTY_DRWAV_DIRECTORY_NOT_EMPTY : Int8 = -16

public const DRWAV_END_OF_FILE_DRWAV_END_OF_FILE : Int8 = -17

public const DRWAV_NO_SPACE_DRWAV_NO_SPACE : Int8 = -18

public const DRWAV_BUSY_DRWAV_BUSY : Int8 = -19

public const DRWAV_IO_ERROR_DRWAV_IO_ERROR : Int8 = -20

public const DRWAV_INTERRUPT_DRWAV_INTERRUPT : Int8 = -21

public const DRWAV_UNAVAILABLE_DRWAV_UNAVAILABLE : Int8 = -22

public const DRWAV_ALREADY_IN_USE_DRWAV_ALREADY_IN_USE : Int8 = -23

public const DRWAV_BAD_ADDRESS_DRWAV_BAD_ADDRESS : Int8 = -24

public const DRWAV_BAD_SEEK_DRWAV_BAD_SEEK : Int8 = -25

public const DRWAV_BAD_PIPE_DRWAV_BAD_PIPE : Int8 = -26

public const DRWAV_DEADLOCK_DRWAV_DEADLOCK : Int8 = -27

public const DRWAV_TOO_MANY_LINKS_DRWAV_TOO_MANY_LINKS : Int8 = -28

public const DRWAV_NOT_IMPLEMENTED_DRWAV_NOT_IMPLEMENTED : Int8 = -29

public const DRWAV_NO_MESSAGE_DRWAV_NO_MESSAGE : Int8 = -30

public const DRWAV_BAD_MESSAGE_DRWAV_BAD_MESSAGE : Int8 = -31

public const DRWAV_NO_DATA_AVAILABLE_DRWAV_NO_DATA_AVAILABLE : Int8 = -32

public const DRWAV_INVALID_DATA_DRWAV_INVALID_DATA : Int8 = -33

public const DRWAV_TIMEOUT_DRWAV_TIMEOUT : Int8 = -34

public const DRWAV_NO_NETWORK_DRWAV_NO_NETWORK : Int8 = -35

public const DRWAV_NOT_UNIQUE_DRWAV_NOT_UNIQUE : Int8 = -36

public const DRWAV_NOT_SOCKET_DRWAV_NOT_SOCKET : Int8 = -37

public const DRWAV_NO_ADDRESS_DRWAV_NO_ADDRESS : Int8 = -38

public const DRWAV_BAD_PROTOCOL_DRWAV_BAD_PROTOCOL : Int8 = -39

public const DRWAV_PROTOCOL_UNAVAILABLE_DRWAV_PROTOCOL_UNAVAILABLE : Int8 = -40

public const DRWAV_PROTOCOL_NOT_SUPPORTED_DRWAV_PROTOCOL_NOT_SUPPORTED : Int8 = -41

public const DRWAV_PROTOCOL_FAMILY_NOT_SUPPORTED_DRWAV_PROTOCOL_FAMILY_NOT_SUPPORTED : Int8 = -42

public const DRWAV_ADDRESS_FAMILY_NOT_SUPPORTED_DRWAV_ADDRESS_FAMILY_NOT_SUPPORTED : Int8 = -43

public const DRWAV_SOCKET_NOT_SUPPORTED_DRWAV_SOCKET_NOT_SUPPORTED : Int8 = -44

public const DRWAV_CONNECTION_RESET_DRWAV_CONNECTION_RESET : Int8 = -45

public const DRWAV_ALREADY_CONNECTED_DRWAV_ALREADY_CONNECTED : Int8 = -46

public const DRWAV_NOT_CONNECTED_DRWAV_NOT_CONNECTED : Int8 = -47

public const DRWAV_CONNECTION_REFUSED_DRWAV_CONNECTION_REFUSED : Int8 = -48

public const DRWAV_NO_HOST_DRWAV_NO_HOST : Int8 = -49

public const DRWAV_IN_PROGRESS_DRWAV_IN_PROGRESS : Int8 = -50

public const DRWAV_CANCELLED_DRWAV_CANCELLED : Int8 = -51

public const DRWAV_MEMORY_ALREADY_MAPPED_DRWAV_MEMORY_ALREADY_MAPPED : Int8 = -52

public const DRWAV_AT_END_DRWAV_AT_END : Int8 = -53

public const DR_WAVE_FORMAT_PCM_DR_WAVE_FORMAT_PCM : Int8 = 1

public const DR_WAVE_FORMAT_ADPCM_DR_WAVE_FORMAT_ADPCM : Int8 = 2

public const DR_WAVE_FORMAT_IEEE_FLOAT_DR_WAVE_FORMAT_IEEE_FLOAT : Int8 = 3

public const DR_WAVE_FORMAT_ALAW_DR_WAVE_FORMAT_ALAW : Int8 = 6

public const DR_WAVE_FORMAT_MULAW_DR_WAVE_FORMAT_MULAW : Int8 = 7

public const DR_WAVE_FORMAT_DTS_DR_WAVE_FORMAT_DTS : Int8 = 8

public const DR_WAVE_FORMAT_DVI_ADPCM_DR_WAVE_FORMAT_DVI_ADPCM : Int8 = 17

public const DR_WAVE_FORMAT_EXTENSIBLE_DR_WAVE_FORMAT_EXTENSIBLE : Int32 = 65534

public const DRWAV_SEQUENTIAL_DRWAV_SEQUENTIAL : Int8 = 1

public const DRWAV_WITH_METADATA_DRWAV_WITH_METADATA : Int8 = 2

public type drwav_int8_drwav_int8 = Int8

public type drwav_uint8_drwav_uint8 = UInt8

public type drwav_int16_drwav_int16 = Int16

public type drwav_uint16_drwav_uint16 = UInt16

public type drwav_int32_drwav_int32 = Int32

public type drwav_uint32_drwav_uint32 = UInt32

public type drwav_int64_drwav_int64 = Int64

public type drwav_uint64_drwav_uint64 = UInt64

public type drwav_uintptr_drwav_uintptr = drwav_uint64_drwav_uint64

public type drwav_bool8_drwav_bool8 = drwav_uint8_drwav_uint8

public type drwav_bool32_drwav_bool32 = drwav_uint32_drwav_uint32

public type drwav_result_drwav_result = drwav_int32_drwav_int32

foreign func drwav_version ( pMajor: CPointer<drwav_uint32_drwav_uint32> , pMinor: CPointer<drwav_uint32_drwav_uint32> , pRevision: CPointer<drwav_uint32_drwav_uint32> ) : Unit

foreign func drwav_version_string (  ) : CString

@C
public struct drwav_allocation_callbacks_drwav_allocation_callbacks {
public let pUserData : CPointer<Unit>
public let onMalloc : CFunc<(sz: UIntNative , pUserData: CPointer<Unit>) -> CPointer<Unit>>
public let onRealloc : CFunc<(p: CPointer<Unit> , sz: UIntNative , pUserData: CPointer<Unit>) -> CPointer<Unit>>
public let onFree : CFunc<(p: CPointer<Unit> , pUserData: CPointer<Unit>) -> Unit>
public init(pUserData : CPointer<Unit> , onMalloc : CFunc<(sz: UIntNative , pUserData: CPointer<Unit>) -> CPointer<Unit>> , onRealloc : CFunc<(p: CPointer<Unit> , sz: UIntNative , pUserData: CPointer<Unit>) -> CPointer<Unit>> , onFree : CFunc<(p: CPointer<Unit> , pUserData: CPointer<Unit>) -> Unit>) {
    this.pUserData = pUserData
this.onMalloc = onMalloc
this.onRealloc = onRealloc
this.onFree = onFree
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_allocation_callbacks_drwav_allocation_callbacks>()
    if (size != 32) {
        throw Exception("Size of drwav_allocation_callbacks_drwav_allocation_callbacks is not 32 but ${size} bytes")
    }
    let align = alignOf<drwav_allocation_callbacks_drwav_allocation_callbacks>()
    if (align != 8) {
        throw Exception("Alignment of drwav_allocation_callbacks_drwav_allocation_callbacks is not 8 but ${align} bytes")
    }
}

public const drwav_seek_origin_DRWAV_SEEK_SET : drwav_seek_origin_drwav_seek_origin = 0

public const drwav_seek_origin_DRWAV_SEEK_CUR : drwav_seek_origin_drwav_seek_origin = 1

public const drwav_seek_origin_DRWAV_SEEK_END : drwav_seek_origin_drwav_seek_origin = 2

public type drwav_seek_origin_drwav_seek_origin = UInt32

public const drwav_container_drwav_container_riff : drwav_container_drwav_container = 0

public const drwav_container_drwav_container_rifx : drwav_container_drwav_container = 1

public const drwav_container_drwav_container_w64 : drwav_container_drwav_container = 2

public const drwav_container_drwav_container_rf64 : drwav_container_drwav_container = 3

public const drwav_container_drwav_container_aiff : drwav_container_drwav_container = 4

public type drwav_container_drwav_container = UInt32

@C
public struct drwav_chunk_header__cjbind_ty_1 {
var _storage: VArray<UInt8, $16> = unsafe { zeroValue<VArray<UInt8, $16>>() }
public init() {}
public func fourcc(): VArray<drwav_uint8_drwav_uint8, $4> {
    var s = this._storage
    return unsafe { __cjbind_read_VArray<drwav_uint8_drwav_uint8,$4>(CPointer<UInt8>(inout s)) }
}
public mut func fourcc(val!: VArray<drwav_uint8_drwav_uint8, $4>): Unit {
    unsafe { __cjbind_write_VArray<drwav_uint8_drwav_uint8,$4>(CPointer<UInt8>(inout this._storage), val) }
}
public func guid(): VArray<drwav_uint8_drwav_uint8, $16> {
    var s = this._storage
    return unsafe { __cjbind_read_VArray<drwav_uint8_drwav_uint8,$16>(CPointer<UInt8>(inout s)) }
}
public mut func guid(val!: VArray<drwav_uint8_drwav_uint8, $16>): Unit {
    unsafe { __cjbind_write_VArray<drwav_uint8_drwav_uint8,$16>(CPointer<UInt8>(inout this._storage), val) }
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_chunk_header__cjbind_ty_1>()
    if (size != 16) {
        throw Exception("Size of drwav_chunk_header__cjbind_ty_1 is not 16 but ${size} bytes")
    }
    let align = alignOf<drwav_chunk_header__cjbind_ty_1>()
    if (align != 1) {
        throw Exception("Alignment of drwav_chunk_header__cjbind_ty_1 is not 1 but ${align} bytes")
    }
}

@C
public struct drwav_chunk_header_drwav_chunk_header {
public let id : drwav_chunk_header__cjbind_ty_1
public let __cjbind_anon_1 : drwav_chunk_header__cjbind_ty_1
public let sizeInBytes : drwav_uint64_drwav_uint64
public let paddingSize : UInt32
public init(id : drwav_chunk_header__cjbind_ty_1 , __cjbind_anon_1 : drwav_chunk_header__cjbind_ty_1 , sizeInBytes : drwav_uint64_drwav_uint64 , paddingSize : UInt32) {
    this.id = id
this.__cjbind_anon_1 = __cjbind_anon_1
this.sizeInBytes = sizeInBytes
this.paddingSize = paddingSize
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_chunk_header_drwav_chunk_header>()
    if (size != 32) {
        throw Exception("Size of drwav_chunk_header_drwav_chunk_header is not 32 but ${size} bytes")
    }
    let align = alignOf<drwav_chunk_header_drwav_chunk_header>()
    if (align != 8) {
        throw Exception("Alignment of drwav_chunk_header_drwav_chunk_header is not 8 but ${align} bytes")
    }
}

@C
public struct drwav_fmt_drwav_fmt {
public let formatTag : drwav_uint16_drwav_uint16
public let channels : drwav_uint16_drwav_uint16
public let sampleRate : drwav_uint32_drwav_uint32
public let avgBytesPerSec : drwav_uint32_drwav_uint32
public let blockAlign : drwav_uint16_drwav_uint16
public let bitsPerSample : drwav_uint16_drwav_uint16
public let extendedSize : drwav_uint16_drwav_uint16
public let validBitsPerSample : drwav_uint16_drwav_uint16
public let channelMask : drwav_uint32_drwav_uint32
public let subFormat : VArray<drwav_uint8_drwav_uint8, $16>
public init(formatTag : drwav_uint16_drwav_uint16 , channels : drwav_uint16_drwav_uint16 , sampleRate : drwav_uint32_drwav_uint32 , avgBytesPerSec : drwav_uint32_drwav_uint32 , blockAlign : drwav_uint16_drwav_uint16 , bitsPerSample : drwav_uint16_drwav_uint16 , extendedSize : drwav_uint16_drwav_uint16 , validBitsPerSample : drwav_uint16_drwav_uint16 , channelMask : drwav_uint32_drwav_uint32 , subFormat : VArray<drwav_uint8_drwav_uint8, $16>) {
    this.formatTag = formatTag
this.channels = channels
this.sampleRate = sampleRate
this.avgBytesPerSec = avgBytesPerSec
this.blockAlign = blockAlign
this.bitsPerSample = bitsPerSample
this.extendedSize = extendedSize
this.validBitsPerSample = validBitsPerSample
this.channelMask = channelMask
this.subFormat = subFormat
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_fmt_drwav_fmt>()
    if (size != 40) {
        throw Exception("Size of drwav_fmt_drwav_fmt is not 40 but ${size} bytes")
    }
    let align = alignOf<drwav_fmt_drwav_fmt>()
    if (align != 4) {
        throw Exception("Alignment of drwav_fmt_drwav_fmt is not 4 but ${align} bytes")
    }
}

foreign func drwav_fmt_get_format ( pFMT: CPointer<drwav_fmt_drwav_fmt> ) : drwav_uint16_drwav_uint16

public type drwav_read_proc_drwav_read_proc = CFunc<(pUserData: CPointer<Unit> , pBufferOut: CPointer<Unit> , bytesToRead: UIntNative) -> UIntNative>

public type drwav_write_proc_drwav_write_proc = CFunc<(pUserData: CPointer<Unit> , pData: CPointer<Unit> , bytesToWrite: UIntNative) -> UIntNative>

public type drwav_seek_proc_drwav_seek_proc = CFunc<(pUserData: CPointer<Unit> , offset: Int32 , origin: drwav_seek_origin_drwav_seek_origin) -> drwav_bool32_drwav_bool32>

public type drwav_tell_proc_drwav_tell_proc = CFunc<(pUserData: CPointer<Unit> , pCursor: CPointer<drwav_int64_drwav_int64>) -> drwav_bool32_drwav_bool32>

public type drwav_chunk_proc_drwav_chunk_proc = CFunc<(pChunkUserData: CPointer<Unit> , onRead: drwav_read_proc_drwav_read_proc , onSeek: drwav_seek_proc_drwav_seek_proc , pReadSeekUserData: CPointer<Unit> , pChunkHeader: CPointer<drwav_chunk_header_drwav_chunk_header> , container: drwav_container_drwav_container , pFMT: CPointer<drwav_fmt_drwav_fmt>) -> drwav_uint64_drwav_uint64>

@C
public struct drwav__memory_stream_drwav__memory_stream {
public let data : CString
public let dataSize : UIntNative
public let currentReadPos : UIntNative
public init(data : CString , dataSize : UIntNative , currentReadPos : UIntNative) {
    this.data = data
this.dataSize = dataSize
this.currentReadPos = currentReadPos
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav__memory_stream_drwav__memory_stream>()
    if (size != 24) {
        throw Exception("Size of drwav__memory_stream_drwav__memory_stream is not 24 but ${size} bytes")
    }
    let align = alignOf<drwav__memory_stream_drwav__memory_stream>()
    if (align != 8) {
        throw Exception("Alignment of drwav__memory_stream_drwav__memory_stream is not 8 but ${align} bytes")
    }
}

@C
public struct drwav__memory_stream_write_drwav__memory_stream_write {
public let ppData : CPointer<CPointer<Unit>>
public let pDataSize : CPointer<UIntNative>
public let dataSize : UIntNative
public let dataCapacity : UIntNative
public let currentWritePos : UIntNative
public init(ppData : CPointer<CPointer<Unit>> , pDataSize : CPointer<UIntNative> , dataSize : UIntNative , dataCapacity : UIntNative , currentWritePos : UIntNative) {
    this.ppData = ppData
this.pDataSize = pDataSize
this.dataSize = dataSize
this.dataCapacity = dataCapacity
this.currentWritePos = currentWritePos
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav__memory_stream_write_drwav__memory_stream_write>()
    if (size != 40) {
        throw Exception("Size of drwav__memory_stream_write_drwav__memory_stream_write is not 40 but ${size} bytes")
    }
    let align = alignOf<drwav__memory_stream_write_drwav__memory_stream_write>()
    if (align != 8) {
        throw Exception("Alignment of drwav__memory_stream_write_drwav__memory_stream_write is not 8 but ${align} bytes")
    }
}

@C
public struct drwav_data_format_drwav_data_format {
public let container : drwav_container_drwav_container
public let format : drwav_uint32_drwav_uint32
public let channels : drwav_uint32_drwav_uint32
public let sampleRate : drwav_uint32_drwav_uint32
public let bitsPerSample : drwav_uint32_drwav_uint32
public init(container : drwav_container_drwav_container , format : drwav_uint32_drwav_uint32 , channels : drwav_uint32_drwav_uint32 , sampleRate : drwav_uint32_drwav_uint32 , bitsPerSample : drwav_uint32_drwav_uint32) {
    this.container = container
this.format = format
this.channels = channels
this.sampleRate = sampleRate
this.bitsPerSample = bitsPerSample
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_data_format_drwav_data_format>()
    if (size != 20) {
        throw Exception("Size of drwav_data_format_drwav_data_format is not 20 but ${size} bytes")
    }
    let align = alignOf<drwav_data_format_drwav_data_format>()
    if (align != 4) {
        throw Exception("Alignment of drwav_data_format_drwav_data_format is not 4 but ${align} bytes")
    }
}

public const drwav_metadata_type_drwav_metadata_type_none : drwav_metadata_type_drwav_metadata_type = 0

public const drwav_metadata_type_drwav_metadata_type_unknown : drwav_metadata_type_drwav_metadata_type = 1

public const drwav_metadata_type_drwav_metadata_type_smpl : drwav_metadata_type_drwav_metadata_type = 2

public const drwav_metadata_type_drwav_metadata_type_inst : drwav_metadata_type_drwav_metadata_type = 4

public const drwav_metadata_type_drwav_metadata_type_cue : drwav_metadata_type_drwav_metadata_type = 8

public const drwav_metadata_type_drwav_metadata_type_acid : drwav_metadata_type_drwav_metadata_type = 16

public const drwav_metadata_type_drwav_metadata_type_bext : drwav_metadata_type_drwav_metadata_type = 32

public const drwav_metadata_type_drwav_metadata_type_list_label : drwav_metadata_type_drwav_metadata_type = 64

public const drwav_metadata_type_drwav_metadata_type_list_note : drwav_metadata_type_drwav_metadata_type = 128

public const drwav_metadata_type_drwav_metadata_type_list_labelled_cue_region : drwav_metadata_type_drwav_metadata_type = 256

public const drwav_metadata_type_drwav_metadata_type_list_info_software : drwav_metadata_type_drwav_metadata_type = 512

public const drwav_metadata_type_drwav_metadata_type_list_info_copyright : drwav_metadata_type_drwav_metadata_type = 1024

public const drwav_metadata_type_drwav_metadata_type_list_info_title : drwav_metadata_type_drwav_metadata_type = 2048

public const drwav_metadata_type_drwav_metadata_type_list_info_artist : drwav_metadata_type_drwav_metadata_type = 4096

public const drwav_metadata_type_drwav_metadata_type_list_info_comment : drwav_metadata_type_drwav_metadata_type = 8192

public const drwav_metadata_type_drwav_metadata_type_list_info_date : drwav_metadata_type_drwav_metadata_type = 16384

public const drwav_metadata_type_drwav_metadata_type_list_info_genre : drwav_metadata_type_drwav_metadata_type = 32768

public const drwav_metadata_type_drwav_metadata_type_list_info_album : drwav_metadata_type_drwav_metadata_type = 65536

public const drwav_metadata_type_drwav_metadata_type_list_info_tracknumber : drwav_metadata_type_drwav_metadata_type = 131072

public const drwav_metadata_type_drwav_metadata_type_list_info_location : drwav_metadata_type_drwav_metadata_type = 262144

public const drwav_metadata_type_drwav_metadata_type_list_info_organization : drwav_metadata_type_drwav_metadata_type = 524288

public const drwav_metadata_type_drwav_metadata_type_list_info_keywords : drwav_metadata_type_drwav_metadata_type = 1048576

public const drwav_metadata_type_drwav_metadata_type_list_info_medium : drwav_metadata_type_drwav_metadata_type = 2097152

public const drwav_metadata_type_drwav_metadata_type_list_info_description : drwav_metadata_type_drwav_metadata_type = 4194304

public const drwav_metadata_type_drwav_metadata_type_list_all_info_strings : drwav_metadata_type_drwav_metadata_type = 8388096

public const drwav_metadata_type_drwav_metadata_type_list_all_adtl : drwav_metadata_type_drwav_metadata_type = 448

public const drwav_metadata_type_drwav_metadata_type_all : drwav_metadata_type_drwav_metadata_type = -2

public const drwav_metadata_type_drwav_metadata_type_all_including_unknown : drwav_metadata_type_drwav_metadata_type = -1

public type drwav_metadata_type_drwav_metadata_type = Int32

public const drwav_smpl_loop_type_drwav_smpl_loop_type_forward : drwav_smpl_loop_type_drwav_smpl_loop_type = 0

public const drwav_smpl_loop_type_drwav_smpl_loop_type_pingpong : drwav_smpl_loop_type_drwav_smpl_loop_type = 1

public const drwav_smpl_loop_type_drwav_smpl_loop_type_backward : drwav_smpl_loop_type_drwav_smpl_loop_type = 2

public type drwav_smpl_loop_type_drwav_smpl_loop_type = UInt32

@C
public struct drwav_smpl_loop_drwav_smpl_loop {
public let cuePointId : drwav_uint32_drwav_uint32
public let type_ : drwav_uint32_drwav_uint32
public let firstSampleOffset : drwav_uint32_drwav_uint32
public let lastSampleOffset : drwav_uint32_drwav_uint32
public let sampleFraction : drwav_uint32_drwav_uint32
public let playCount : drwav_uint32_drwav_uint32
public init(cuePointId : drwav_uint32_drwav_uint32 , type_ : drwav_uint32_drwav_uint32 , firstSampleOffset : drwav_uint32_drwav_uint32 , lastSampleOffset : drwav_uint32_drwav_uint32 , sampleFraction : drwav_uint32_drwav_uint32 , playCount : drwav_uint32_drwav_uint32) {
    this.cuePointId = cuePointId
this.type_ = type_
this.firstSampleOffset = firstSampleOffset
this.lastSampleOffset = lastSampleOffset
this.sampleFraction = sampleFraction
this.playCount = playCount
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_smpl_loop_drwav_smpl_loop>()
    if (size != 24) {
        throw Exception("Size of drwav_smpl_loop_drwav_smpl_loop is not 24 but ${size} bytes")
    }
    let align = alignOf<drwav_smpl_loop_drwav_smpl_loop>()
    if (align != 4) {
        throw Exception("Alignment of drwav_smpl_loop_drwav_smpl_loop is not 4 but ${align} bytes")
    }
}

@C
public struct drwav_smpl_drwav_smpl {
public let manufacturerId : drwav_uint32_drwav_uint32
public let productId : drwav_uint32_drwav_uint32
public let samplePeriodNanoseconds : drwav_uint32_drwav_uint32
public let midiUnityNote : drwav_uint32_drwav_uint32
public let midiPitchFraction : drwav_uint32_drwav_uint32
public let smpteFormat : drwav_uint32_drwav_uint32
public let smpteOffset : drwav_uint32_drwav_uint32
public let sampleLoopCount : drwav_uint32_drwav_uint32
public let samplerSpecificDataSizeInBytes : drwav_uint32_drwav_uint32
public let pLoops : CPointer<drwav_smpl_loop_drwav_smpl_loop>
public let pSamplerSpecificData : CString
public init(manufacturerId : drwav_uint32_drwav_uint32 , productId : drwav_uint32_drwav_uint32 , samplePeriodNanoseconds : drwav_uint32_drwav_uint32 , midiUnityNote : drwav_uint32_drwav_uint32 , midiPitchFraction : drwav_uint32_drwav_uint32 , smpteFormat : drwav_uint32_drwav_uint32 , smpteOffset : drwav_uint32_drwav_uint32 , sampleLoopCount : drwav_uint32_drwav_uint32 , samplerSpecificDataSizeInBytes : drwav_uint32_drwav_uint32 , pLoops : CPointer<drwav_smpl_loop_drwav_smpl_loop> , pSamplerSpecificData : CString) {
    this.manufacturerId = manufacturerId
this.productId = productId
this.samplePeriodNanoseconds = samplePeriodNanoseconds
this.midiUnityNote = midiUnityNote
this.midiPitchFraction = midiPitchFraction
this.smpteFormat = smpteFormat
this.smpteOffset = smpteOffset
this.sampleLoopCount = sampleLoopCount
this.samplerSpecificDataSizeInBytes = samplerSpecificDataSizeInBytes
this.pLoops = pLoops
this.pSamplerSpecificData = pSamplerSpecificData
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_smpl_drwav_smpl>()
    if (size != 56) {
        throw Exception("Size of drwav_smpl_drwav_smpl is not 56 but ${size} bytes")
    }
    let align = alignOf<drwav_smpl_drwav_smpl>()
    if (align != 8) {
        throw Exception("Alignment of drwav_smpl_drwav_smpl is not 8 but ${align} bytes")
    }
}

@C
public struct drwav_inst_drwav_inst {
public let midiUnityNote : drwav_int8_drwav_int8
public let fineTuneCents : drwav_int8_drwav_int8
public let gainDecibels : drwav_int8_drwav_int8
public let lowNote : drwav_int8_drwav_int8
public let highNote : drwav_int8_drwav_int8
public let lowVelocity : drwav_int8_drwav_int8
public let highVelocity : drwav_int8_drwav_int8
public init(midiUnityNote : drwav_int8_drwav_int8 , fineTuneCents : drwav_int8_drwav_int8 , gainDecibels : drwav_int8_drwav_int8 , lowNote : drwav_int8_drwav_int8 , highNote : drwav_int8_drwav_int8 , lowVelocity : drwav_int8_drwav_int8 , highVelocity : drwav_int8_drwav_int8) {
    this.midiUnityNote = midiUnityNote
this.fineTuneCents = fineTuneCents
this.gainDecibels = gainDecibels
this.lowNote = lowNote
this.highNote = highNote
this.lowVelocity = lowVelocity
this.highVelocity = highVelocity
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_inst_drwav_inst>()
    if (size != 7) {
        throw Exception("Size of drwav_inst_drwav_inst is not 7 but ${size} bytes")
    }
    let align = alignOf<drwav_inst_drwav_inst>()
    if (align != 1) {
        throw Exception("Alignment of drwav_inst_drwav_inst is not 1 but ${align} bytes")
    }
}

@C
public struct drwav_cue_point_drwav_cue_point {
public let id : drwav_uint32_drwav_uint32
public let playOrderPosition : drwav_uint32_drwav_uint32
public let dataChunkId : VArray<drwav_uint8_drwav_uint8, $4>
public let chunkStart : drwav_uint32_drwav_uint32
public let blockStart : drwav_uint32_drwav_uint32
public let sampleOffset : drwav_uint32_drwav_uint32
public init(id : drwav_uint32_drwav_uint32 , playOrderPosition : drwav_uint32_drwav_uint32 , dataChunkId : VArray<drwav_uint8_drwav_uint8, $4> , chunkStart : drwav_uint32_drwav_uint32 , blockStart : drwav_uint32_drwav_uint32 , sampleOffset : drwav_uint32_drwav_uint32) {
    this.id = id
this.playOrderPosition = playOrderPosition
this.dataChunkId = dataChunkId
this.chunkStart = chunkStart
this.blockStart = blockStart
this.sampleOffset = sampleOffset
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_cue_point_drwav_cue_point>()
    if (size != 24) {
        throw Exception("Size of drwav_cue_point_drwav_cue_point is not 24 but ${size} bytes")
    }
    let align = alignOf<drwav_cue_point_drwav_cue_point>()
    if (align != 4) {
        throw Exception("Alignment of drwav_cue_point_drwav_cue_point is not 4 but ${align} bytes")
    }
}

@C
public struct drwav_cue_drwav_cue {
public let cuePointCount : drwav_uint32_drwav_uint32
public let pCuePoints : CPointer<drwav_cue_point_drwav_cue_point>
public init(cuePointCount : drwav_uint32_drwav_uint32 , pCuePoints : CPointer<drwav_cue_point_drwav_cue_point>) {
    this.cuePointCount = cuePointCount
this.pCuePoints = pCuePoints
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_cue_drwav_cue>()
    if (size != 16) {
        throw Exception("Size of drwav_cue_drwav_cue is not 16 but ${size} bytes")
    }
    let align = alignOf<drwav_cue_drwav_cue>()
    if (align != 8) {
        throw Exception("Alignment of drwav_cue_drwav_cue is not 8 but ${align} bytes")
    }
}

public const drwav_acid_flag_drwav_acid_flag_one_shot : drwav_acid_flag_drwav_acid_flag = 1

public const drwav_acid_flag_drwav_acid_flag_root_note_set : drwav_acid_flag_drwav_acid_flag = 2

public const drwav_acid_flag_drwav_acid_flag_stretch : drwav_acid_flag_drwav_acid_flag = 4

public const drwav_acid_flag_drwav_acid_flag_disk_based : drwav_acid_flag_drwav_acid_flag = 8

public const drwav_acid_flag_drwav_acid_flag_acidizer : drwav_acid_flag_drwav_acid_flag = 16

public type drwav_acid_flag_drwav_acid_flag = UInt32

@C
public struct drwav_acid_drwav_acid {
public let flags : drwav_uint32_drwav_uint32
public let midiUnityNote : drwav_uint16_drwav_uint16
public let reserved1 : drwav_uint16_drwav_uint16
public let reserved2 : Float32
public let numBeats : drwav_uint32_drwav_uint32
public let meterDenominator : drwav_uint16_drwav_uint16
public let meterNumerator : drwav_uint16_drwav_uint16
public let tempo : Float32
public init(flags : drwav_uint32_drwav_uint32 , midiUnityNote : drwav_uint16_drwav_uint16 , reserved1 : drwav_uint16_drwav_uint16 , reserved2 : Float32 , numBeats : drwav_uint32_drwav_uint32 , meterDenominator : drwav_uint16_drwav_uint16 , meterNumerator : drwav_uint16_drwav_uint16 , tempo : Float32) {
    this.flags = flags
this.midiUnityNote = midiUnityNote
this.reserved1 = reserved1
this.reserved2 = reserved2
this.numBeats = numBeats
this.meterDenominator = meterDenominator
this.meterNumerator = meterNumerator
this.tempo = tempo
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_acid_drwav_acid>()
    if (size != 24) {
        throw Exception("Size of drwav_acid_drwav_acid is not 24 but ${size} bytes")
    }
    let align = alignOf<drwav_acid_drwav_acid>()
    if (align != 4) {
        throw Exception("Alignment of drwav_acid_drwav_acid is not 4 but ${align} bytes")
    }
}

@C
public struct drwav_list_label_or_note_drwav_list_label_or_note {
public let cuePointId : drwav_uint32_drwav_uint32
public let stringLength : drwav_uint32_drwav_uint32
public let pString : CString
public init(cuePointId : drwav_uint32_drwav_uint32 , stringLength : drwav_uint32_drwav_uint32 , pString : CString) {
    this.cuePointId = cuePointId
this.stringLength = stringLength
this.pString = pString
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_list_label_or_note_drwav_list_label_or_note>()
    if (size != 16) {
        throw Exception("Size of drwav_list_label_or_note_drwav_list_label_or_note is not 16 but ${size} bytes")
    }
    let align = alignOf<drwav_list_label_or_note_drwav_list_label_or_note>()
    if (align != 8) {
        throw Exception("Alignment of drwav_list_label_or_note_drwav_list_label_or_note is not 8 but ${align} bytes")
    }
}

@C
public struct drwav_bext_drwav_bext {
public let pDescription : CString
public let pOriginatorName : CString
public let pOriginatorReference : CString
public let pOriginationDate : VArray<UInt8, $10>
public let pOriginationTime : VArray<UInt8, $8>
public let timeReference : drwav_uint64_drwav_uint64
public let version : drwav_uint16_drwav_uint16
public let pCodingHistory : CString
public let codingHistorySize : drwav_uint32_drwav_uint32
public let pUMID : CString
public let loudnessValue : drwav_uint16_drwav_uint16
public let loudnessRange : drwav_uint16_drwav_uint16
public let maxTruePeakLevel : drwav_uint16_drwav_uint16
public let maxMomentaryLoudness : drwav_uint16_drwav_uint16
public let maxShortTermLoudness : drwav_uint16_drwav_uint16
public init(pDescription : CString , pOriginatorName : CString , pOriginatorReference : CString , pOriginationDate : VArray<UInt8, $10> , pOriginationTime : VArray<UInt8, $8> , timeReference : drwav_uint64_drwav_uint64 , version : drwav_uint16_drwav_uint16 , pCodingHistory : CString , codingHistorySize : drwav_uint32_drwav_uint32 , pUMID : CString , loudnessValue : drwav_uint16_drwav_uint16 , loudnessRange : drwav_uint16_drwav_uint16 , maxTruePeakLevel : drwav_uint16_drwav_uint16 , maxMomentaryLoudness : drwav_uint16_drwav_uint16 , maxShortTermLoudness : drwav_uint16_drwav_uint16) {
    this.pDescription = pDescription
this.pOriginatorName = pOriginatorName
this.pOriginatorReference = pOriginatorReference
this.pOriginationDate = pOriginationDate
this.pOriginationTime = pOriginationTime
this.timeReference = timeReference
this.version = version
this.pCodingHistory = pCodingHistory
this.codingHistorySize = codingHistorySize
this.pUMID = pUMID
this.loudnessValue = loudnessValue
this.loudnessRange = loudnessRange
this.maxTruePeakLevel = maxTruePeakLevel
this.maxMomentaryLoudness = maxMomentaryLoudness
this.maxShortTermLoudness = maxShortTermLoudness
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_bext_drwav_bext>()
    if (size != 104) {
        throw Exception("Size of drwav_bext_drwav_bext is not 104 but ${size} bytes")
    }
    let align = alignOf<drwav_bext_drwav_bext>()
    if (align != 8) {
        throw Exception("Alignment of drwav_bext_drwav_bext is not 8 but ${align} bytes")
    }
}

@C
public struct drwav_list_info_text_drwav_list_info_text {
public let stringLength : drwav_uint32_drwav_uint32
public let pString : CString
public init(stringLength : drwav_uint32_drwav_uint32 , pString : CString) {
    this.stringLength = stringLength
this.pString = pString
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_list_info_text_drwav_list_info_text>()
    if (size != 16) {
        throw Exception("Size of drwav_list_info_text_drwav_list_info_text is not 16 but ${size} bytes")
    }
    let align = alignOf<drwav_list_info_text_drwav_list_info_text>()
    if (align != 8) {
        throw Exception("Alignment of drwav_list_info_text_drwav_list_info_text is not 8 but ${align} bytes")
    }
}

@C
public struct drwav_list_labelled_cue_region_drwav_list_labelled_cue_region {
public let cuePointId : drwav_uint32_drwav_uint32
public let sampleLength : drwav_uint32_drwav_uint32
public let purposeId : VArray<drwav_uint8_drwav_uint8, $4>
public let country : drwav_uint16_drwav_uint16
public let language : drwav_uint16_drwav_uint16
public let dialect : drwav_uint16_drwav_uint16
public let codePage : drwav_uint16_drwav_uint16
public let stringLength : drwav_uint32_drwav_uint32
public let pString : CString
public init(cuePointId : drwav_uint32_drwav_uint32 , sampleLength : drwav_uint32_drwav_uint32 , purposeId : VArray<drwav_uint8_drwav_uint8, $4> , country : drwav_uint16_drwav_uint16 , language : drwav_uint16_drwav_uint16 , dialect : drwav_uint16_drwav_uint16 , codePage : drwav_uint16_drwav_uint16 , stringLength : drwav_uint32_drwav_uint32 , pString : CString) {
    this.cuePointId = cuePointId
this.sampleLength = sampleLength
this.purposeId = purposeId
this.country = country
this.language = language
this.dialect = dialect
this.codePage = codePage
this.stringLength = stringLength
this.pString = pString
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_list_labelled_cue_region_drwav_list_labelled_cue_region>()
    if (size != 32) {
        throw Exception("Size of drwav_list_labelled_cue_region_drwav_list_labelled_cue_region is not 32 but ${size} bytes")
    }
    let align = alignOf<drwav_list_labelled_cue_region_drwav_list_labelled_cue_region>()
    if (align != 8) {
        throw Exception("Alignment of drwav_list_labelled_cue_region_drwav_list_labelled_cue_region is not 8 but ${align} bytes")
    }
}

public const drwav_metadata_location_drwav_metadata_location_invalid : drwav_metadata_location_drwav_metadata_location = 0

public const drwav_metadata_location_drwav_metadata_location_top_level : drwav_metadata_location_drwav_metadata_location = 1

public const drwav_metadata_location_drwav_metadata_location_inside_info_list : drwav_metadata_location_drwav_metadata_location = 2

public const drwav_metadata_location_drwav_metadata_location_inside_adtl_list : drwav_metadata_location_drwav_metadata_location = 3

public type drwav_metadata_location_drwav_metadata_location = UInt32

@C
public struct drwav_unknown_metadata_drwav_unknown_metadata {
public let id : VArray<drwav_uint8_drwav_uint8, $4>
public let chunkLocation : drwav_metadata_location_drwav_metadata_location
public let dataSizeInBytes : drwav_uint32_drwav_uint32
public let pData : CString
public init(id : VArray<drwav_uint8_drwav_uint8, $4> , chunkLocation : drwav_metadata_location_drwav_metadata_location , dataSizeInBytes : drwav_uint32_drwav_uint32 , pData : CString) {
    this.id = id
this.chunkLocation = chunkLocation
this.dataSizeInBytes = dataSizeInBytes
this.pData = pData
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_unknown_metadata_drwav_unknown_metadata>()
    if (size != 24) {
        throw Exception("Size of drwav_unknown_metadata_drwav_unknown_metadata is not 24 but ${size} bytes")
    }
    let align = alignOf<drwav_unknown_metadata_drwav_unknown_metadata>()
    if (align != 8) {
        throw Exception("Alignment of drwav_unknown_metadata_drwav_unknown_metadata is not 8 but ${align} bytes")
    }
}

@C
public struct drwav_metadata__cjbind_ty_1 {
var _storage: VArray<UInt64, $13> = unsafe { zeroValue<VArray<UInt64, $13>>() }
public init() {}
public func cue(): drwav_cue_drwav_cue {
    var s = this._storage
    return unsafe { __cjbind_read_drwav_cue_drwav_cue(CPointer<UInt8>(inout s)) }
}
public mut func cue(val!: drwav_cue_drwav_cue): Unit {
    unsafe { __cjbind_write_drwav_cue_drwav_cue(CPointer<UInt8>(inout this._storage), val) }
}
public func smpl(): drwav_smpl_drwav_smpl {
    var s = this._storage
    return unsafe { __cjbind_read_drwav_smpl_drwav_smpl(CPointer<UInt8>(inout s)) }
}
public mut func smpl(val!: drwav_smpl_drwav_smpl): Unit {
    unsafe { __cjbind_write_drwav_smpl_drwav_smpl(CPointer<UInt8>(inout this._storage), val) }
}
public func acid(): drwav_acid_drwav_acid {
    var s = this._storage
    return unsafe { __cjbind_read_drwav_acid_drwav_acid(CPointer<UInt8>(inout s)) }
}
public mut func acid(val!: drwav_acid_drwav_acid): Unit {
    unsafe { __cjbind_write_drwav_acid_drwav_acid(CPointer<UInt8>(inout this._storage), val) }
}
public func inst(): drwav_inst_drwav_inst {
    var s = this._storage
    return unsafe { __cjbind_read_drwav_inst_drwav_inst(CPointer<UInt8>(inout s)) }
}
public mut func inst(val!: drwav_inst_drwav_inst): Unit {
    unsafe { __cjbind_write_drwav_inst_drwav_inst(CPointer<UInt8>(inout this._storage), val) }
}
public func bext(): drwav_bext_drwav_bext {
    var s = this._storage
    return unsafe { __cjbind_read_drwav_bext_drwav_bext(CPointer<UInt8>(inout s)) }
}
public mut func bext(val!: drwav_bext_drwav_bext): Unit {
    unsafe { __cjbind_write_drwav_bext_drwav_bext(CPointer<UInt8>(inout this._storage), val) }
}
public func labelOrNote(): drwav_list_label_or_note_drwav_list_label_or_note {
    var s = this._storage
    return unsafe { __cjbind_read_drwav_list_label_or_note_drwav_list_label_or_note(CPointer<UInt8>(inout s)) }
}
public mut func labelOrNote(val!: drwav_list_label_or_note_drwav_list_label_or_note): Unit {
    unsafe { __cjbind_write_drwav_list_label_or_note_drwav_list_label_or_note(CPointer<UInt8>(inout this._storage), val) }
}
public func labelledCueRegion(): drwav_list_labelled_cue_region_drwav_list_labelled_cue_region {
    var s = this._storage
    return unsafe { __cjbind_read_drwav_list_labelled_cue_region_drwav_list_labelled_cue_region(CPointer<UInt8>(inout s)) }
}
public mut func labelledCueRegion(val!: drwav_list_labelled_cue_region_drwav_list_labelled_cue_region): Unit {
    unsafe { __cjbind_write_drwav_list_labelled_cue_region_drwav_list_labelled_cue_region(CPointer<UInt8>(inout this._storage), val) }
}
public func infoText(): drwav_list_info_text_drwav_list_info_text {
    var s = this._storage
    return unsafe { __cjbind_read_drwav_list_info_text_drwav_list_info_text(CPointer<UInt8>(inout s)) }
}
public mut func infoText(val!: drwav_list_info_text_drwav_list_info_text): Unit {
    unsafe { __cjbind_write_drwav_list_info_text_drwav_list_info_text(CPointer<UInt8>(inout this._storage), val) }
}
public func unknown(): drwav_unknown_metadata_drwav_unknown_metadata {
    var s = this._storage
    return unsafe { __cjbind_read_drwav_unknown_metadata_drwav_unknown_metadata(CPointer<UInt8>(inout s)) }
}
public mut func unknown(val!: drwav_unknown_metadata_drwav_unknown_metadata): Unit {
    unsafe { __cjbind_write_drwav_unknown_metadata_drwav_unknown_metadata(CPointer<UInt8>(inout this._storage), val) }
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_metadata__cjbind_ty_1>()
    if (size != 104) {
        throw Exception("Size of drwav_metadata__cjbind_ty_1 is not 104 but ${size} bytes")
    }
    let align = alignOf<drwav_metadata__cjbind_ty_1>()
    if (align != 8) {
        throw Exception("Alignment of drwav_metadata__cjbind_ty_1 is not 8 but ${align} bytes")
    }
}

@C
public struct drwav_metadata_drwav_metadata {
public let type_ : drwav_metadata_type_drwav_metadata_type
public let data : drwav_metadata__cjbind_ty_1
public let __cjbind_anon_1 : drwav_metadata__cjbind_ty_1
public init(type_ : drwav_metadata_type_drwav_metadata_type , data : drwav_metadata__cjbind_ty_1 , __cjbind_anon_1 : drwav_metadata__cjbind_ty_1) {
    this.type_ = type_
this.data = data
this.__cjbind_anon_1 = __cjbind_anon_1
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_metadata_drwav_metadata>()
    if (size != 112) {
        throw Exception("Size of drwav_metadata_drwav_metadata is not 112 but ${size} bytes")
    }
    let align = alignOf<drwav_metadata_drwav_metadata>()
    if (align != 8) {
        throw Exception("Alignment of drwav_metadata_drwav_metadata is not 8 but ${align} bytes")
    }
}

@C
public struct drwav__cjbind_ty_1 {
public let bytesRemainingInBlock : drwav_uint32_drwav_uint32
public let predictor : VArray<drwav_uint16_drwav_uint16, $2>
public let delta : VArray<drwav_int32_drwav_int32, $2>
public let cachedFrames : VArray<drwav_int32_drwav_int32, $4>
public let cachedFrameCount : drwav_uint32_drwav_uint32
public let prevFrames : VArray<VArray<drwav_int32_drwav_int32, $2>, $2>
public init(bytesRemainingInBlock : drwav_uint32_drwav_uint32 , predictor : VArray<drwav_uint16_drwav_uint16, $2> , delta : VArray<drwav_int32_drwav_int32, $2> , cachedFrames : VArray<drwav_int32_drwav_int32, $4> , cachedFrameCount : drwav_uint32_drwav_uint32 , prevFrames : VArray<VArray<drwav_int32_drwav_int32, $2>, $2>) {
    this.bytesRemainingInBlock = bytesRemainingInBlock
this.predictor = predictor
this.delta = delta
this.cachedFrames = cachedFrames
this.cachedFrameCount = cachedFrameCount
this.prevFrames = prevFrames
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav__cjbind_ty_1>()
    if (size != 52) {
        throw Exception("Size of drwav__cjbind_ty_1 is not 52 but ${size} bytes")
    }
    let align = alignOf<drwav__cjbind_ty_1>()
    if (align != 4) {
        throw Exception("Alignment of drwav__cjbind_ty_1 is not 4 but ${align} bytes")
    }
}

@C
public struct drwav__cjbind_ty_2 {
public let bytesRemainingInBlock : drwav_uint32_drwav_uint32
public let predictor : VArray<drwav_int32_drwav_int32, $2>
public let stepIndex : VArray<drwav_int32_drwav_int32, $2>
public let cachedFrames : VArray<drwav_int32_drwav_int32, $16>
public let cachedFrameCount : drwav_uint32_drwav_uint32
public init(bytesRemainingInBlock : drwav_uint32_drwav_uint32 , predictor : VArray<drwav_int32_drwav_int32, $2> , stepIndex : VArray<drwav_int32_drwav_int32, $2> , cachedFrames : VArray<drwav_int32_drwav_int32, $16> , cachedFrameCount : drwav_uint32_drwav_uint32) {
    this.bytesRemainingInBlock = bytesRemainingInBlock
this.predictor = predictor
this.stepIndex = stepIndex
this.cachedFrames = cachedFrames
this.cachedFrameCount = cachedFrameCount
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav__cjbind_ty_2>()
    if (size != 88) {
        throw Exception("Size of drwav__cjbind_ty_2 is not 88 but ${size} bytes")
    }
    let align = alignOf<drwav__cjbind_ty_2>()
    if (align != 4) {
        throw Exception("Alignment of drwav__cjbind_ty_2 is not 4 but ${align} bytes")
    }
}

@C
public struct drwav__cjbind_ty_3 {
public let isLE : drwav_bool8_drwav_bool8
public let isUnsigned : drwav_bool8_drwav_bool8
public init(isLE : drwav_bool8_drwav_bool8 , isUnsigned : drwav_bool8_drwav_bool8) {
    this.isLE = isLE
this.isUnsigned = isUnsigned
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav__cjbind_ty_3>()
    if (size != 2) {
        throw Exception("Size of drwav__cjbind_ty_3 is not 2 but ${size} bytes")
    }
    let align = alignOf<drwav__cjbind_ty_3>()
    if (align != 1) {
        throw Exception("Alignment of drwav__cjbind_ty_3 is not 1 but ${align} bytes")
    }
}

@C
public struct drwav_drwav {
public let onRead : drwav_read_proc_drwav_read_proc
public let onWrite : drwav_write_proc_drwav_write_proc
public let onSeek : drwav_seek_proc_drwav_seek_proc
public let onTell : drwav_tell_proc_drwav_tell_proc
public let pUserData : CPointer<Unit>
public let allocationCallbacks : drwav_allocation_callbacks_drwav_allocation_callbacks
public let container : drwav_container_drwav_container
public let fmt : drwav_fmt_drwav_fmt
public let sampleRate : drwav_uint32_drwav_uint32
public let channels : drwav_uint16_drwav_uint16
public let bitsPerSample : drwav_uint16_drwav_uint16
public let translatedFormatTag : drwav_uint16_drwav_uint16
public let totalPCMFrameCount : drwav_uint64_drwav_uint64
public let dataChunkDataSize : drwav_uint64_drwav_uint64
public let dataChunkDataPos : drwav_uint64_drwav_uint64
public let bytesRemaining : drwav_uint64_drwav_uint64
public let readCursorInPCMFrames : drwav_uint64_drwav_uint64
public let dataChunkDataSizeTargetWrite : drwav_uint64_drwav_uint64
public let isSequentialWrite : drwav_bool32_drwav_bool32
public let pMetadata : CPointer<drwav_metadata_drwav_metadata>
public let metadataCount : drwav_uint32_drwav_uint32
public let memoryStream : drwav__memory_stream_drwav__memory_stream
public let memoryStreamWrite : drwav__memory_stream_write_drwav__memory_stream_write
public let msadpcm : drwav__cjbind_ty_1
public let __cjbind_anon_1 : drwav__cjbind_ty_1
public let ima : drwav__cjbind_ty_2
public let __cjbind_anon_2 : drwav__cjbind_ty_2
public let aiff : drwav__cjbind_ty_3
public let __cjbind_anon_3 : drwav__cjbind_ty_3
public init(onRead : drwav_read_proc_drwav_read_proc , onWrite : drwav_write_proc_drwav_write_proc , onSeek : drwav_seek_proc_drwav_seek_proc , onTell : drwav_tell_proc_drwav_tell_proc , pUserData : CPointer<Unit> , allocationCallbacks : drwav_allocation_callbacks_drwav_allocation_callbacks , container : drwav_container_drwav_container , fmt : drwav_fmt_drwav_fmt , sampleRate : drwav_uint32_drwav_uint32 , channels : drwav_uint16_drwav_uint16 , bitsPerSample : drwav_uint16_drwav_uint16 , translatedFormatTag : drwav_uint16_drwav_uint16 , totalPCMFrameCount : drwav_uint64_drwav_uint64 , dataChunkDataSize : drwav_uint64_drwav_uint64 , dataChunkDataPos : drwav_uint64_drwav_uint64 , bytesRemaining : drwav_uint64_drwav_uint64 , readCursorInPCMFrames : drwav_uint64_drwav_uint64 , dataChunkDataSizeTargetWrite : drwav_uint64_drwav_uint64 , isSequentialWrite : drwav_bool32_drwav_bool32 , pMetadata : CPointer<drwav_metadata_drwav_metadata> , metadataCount : drwav_uint32_drwav_uint32 , memoryStream : drwav__memory_stream_drwav__memory_stream , memoryStreamWrite : drwav__memory_stream_write_drwav__memory_stream_write , msadpcm : drwav__cjbind_ty_1 , __cjbind_anon_1 : drwav__cjbind_ty_1 , ima : drwav__cjbind_ty_2 , __cjbind_anon_2 : drwav__cjbind_ty_2 , aiff : drwav__cjbind_ty_3 , __cjbind_anon_3 : drwav__cjbind_ty_3) {
    this.onRead = onRead
this.onWrite = onWrite
this.onSeek = onSeek
this.onTell = onTell
this.pUserData = pUserData
this.allocationCallbacks = allocationCallbacks
this.container = container
this.fmt = fmt
this.sampleRate = sampleRate
this.channels = channels
this.bitsPerSample = bitsPerSample
this.translatedFormatTag = translatedFormatTag
this.totalPCMFrameCount = totalPCMFrameCount
this.dataChunkDataSize = dataChunkDataSize
this.dataChunkDataPos = dataChunkDataPos
this.bytesRemaining = bytesRemaining
this.readCursorInPCMFrames = readCursorInPCMFrames
this.dataChunkDataSizeTargetWrite = dataChunkDataSizeTargetWrite
this.isSequentialWrite = isSequentialWrite
this.pMetadata = pMetadata
this.metadataCount = metadataCount
this.memoryStream = memoryStream
this.memoryStreamWrite = memoryStreamWrite
this.msadpcm = msadpcm
this.__cjbind_anon_1 = __cjbind_anon_1
this.ima = ima
this.__cjbind_anon_2 = __cjbind_anon_2
this.aiff = aiff
this.__cjbind_anon_3 = __cjbind_anon_3
}
}

@When[debug]
let _ = {
=>
    let size = sizeOf<drwav_drwav>()
    if (size != 408) {
        throw Exception("Size of drwav_drwav is not 408 but ${size} bytes")
    }
    let align = alignOf<drwav_drwav>()
    if (align != 8) {
        throw Exception("Alignment of drwav_drwav is not 8 but ${align} bytes")
    }
}

foreign func drwav_init ( pWav: CPointer<drwav_drwav> , onRead: drwav_read_proc_drwav_read_proc , onSeek: drwav_seek_proc_drwav_seek_proc , onTell: drwav_tell_proc_drwav_tell_proc , pUserData: CPointer<Unit> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_ex ( pWav: CPointer<drwav_drwav> , onRead: drwav_read_proc_drwav_read_proc , onSeek: drwav_seek_proc_drwav_seek_proc , onTell: drwav_tell_proc_drwav_tell_proc , onChunk: drwav_chunk_proc_drwav_chunk_proc , pReadSeekTellUserData: CPointer<Unit> , pChunkUserData: CPointer<Unit> , flags: drwav_uint32_drwav_uint32 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_with_metadata ( pWav: CPointer<drwav_drwav> , onRead: drwav_read_proc_drwav_read_proc , onSeek: drwav_seek_proc_drwav_seek_proc , onTell: drwav_tell_proc_drwav_tell_proc , pUserData: CPointer<Unit> , flags: drwav_uint32_drwav_uint32 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_write ( pWav: CPointer<drwav_drwav> , pFormat: CPointer<drwav_data_format_drwav_data_format> , onWrite: drwav_write_proc_drwav_write_proc , onSeek: drwav_seek_proc_drwav_seek_proc , pUserData: CPointer<Unit> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_write_sequential ( pWav: CPointer<drwav_drwav> , pFormat: CPointer<drwav_data_format_drwav_data_format> , totalSampleCount: drwav_uint64_drwav_uint64 , onWrite: drwav_write_proc_drwav_write_proc , pUserData: CPointer<Unit> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_write_sequential_pcm_frames ( pWav: CPointer<drwav_drwav> , pFormat: CPointer<drwav_data_format_drwav_data_format> , totalPCMFrameCount: drwav_uint64_drwav_uint64 , onWrite: drwav_write_proc_drwav_write_proc , pUserData: CPointer<Unit> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_write_with_metadata ( pWav: CPointer<drwav_drwav> , pFormat: CPointer<drwav_data_format_drwav_data_format> , onWrite: drwav_write_proc_drwav_write_proc , onSeek: drwav_seek_proc_drwav_seek_proc , pUserData: CPointer<Unit> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> , pMetadata: CPointer<drwav_metadata_drwav_metadata> , metadataCount: drwav_uint32_drwav_uint32 ) : drwav_bool32_drwav_bool32

foreign func drwav_target_write_size_bytes ( pFormat: CPointer<drwav_data_format_drwav_data_format> , totalFrameCount: drwav_uint64_drwav_uint64 , pMetadata: CPointer<drwav_metadata_drwav_metadata> , metadataCount: drwav_uint32_drwav_uint32 ) : drwav_uint64_drwav_uint64

foreign func drwav_take_ownership_of_metadata ( pWav: CPointer<drwav_drwav> ) : CPointer<drwav_metadata_drwav_metadata>

foreign func drwav_uninit ( pWav: CPointer<drwav_drwav> ) : drwav_result_drwav_result

foreign func drwav_read_raw ( pWav: CPointer<drwav_drwav> , bytesToRead: UIntNative , pBufferOut: CPointer<Unit> ) : UIntNative

foreign func drwav_read_pcm_frames ( pWav: CPointer<drwav_drwav> , framesToRead: drwav_uint64_drwav_uint64 , pBufferOut: CPointer<Unit> ) : drwav_uint64_drwav_uint64

foreign func drwav_read_pcm_frames_le ( pWav: CPointer<drwav_drwav> , framesToRead: drwav_uint64_drwav_uint64 , pBufferOut: CPointer<Unit> ) : drwav_uint64_drwav_uint64

foreign func drwav_read_pcm_frames_be ( pWav: CPointer<drwav_drwav> , framesToRead: drwav_uint64_drwav_uint64 , pBufferOut: CPointer<Unit> ) : drwav_uint64_drwav_uint64

foreign func drwav_seek_to_pcm_frame ( pWav: CPointer<drwav_drwav> , targetFrameIndex: drwav_uint64_drwav_uint64 ) : drwav_bool32_drwav_bool32

foreign func drwav_get_cursor_in_pcm_frames ( pWav: CPointer<drwav_drwav> , pCursor: CPointer<drwav_uint64_drwav_uint64> ) : drwav_result_drwav_result

foreign func drwav_get_length_in_pcm_frames ( pWav: CPointer<drwav_drwav> , pLength: CPointer<drwav_uint64_drwav_uint64> ) : drwav_result_drwav_result

foreign func drwav_write_raw ( pWav: CPointer<drwav_drwav> , bytesToWrite: UIntNative , pData: CPointer<Unit> ) : UIntNative

foreign func drwav_write_pcm_frames ( pWav: CPointer<drwav_drwav> , framesToWrite: drwav_uint64_drwav_uint64 , pData: CPointer<Unit> ) : drwav_uint64_drwav_uint64

foreign func drwav_write_pcm_frames_le ( pWav: CPointer<drwav_drwav> , framesToWrite: drwav_uint64_drwav_uint64 , pData: CPointer<Unit> ) : drwav_uint64_drwav_uint64

foreign func drwav_write_pcm_frames_be ( pWav: CPointer<drwav_drwav> , framesToWrite: drwav_uint64_drwav_uint64 , pData: CPointer<Unit> ) : drwav_uint64_drwav_uint64

foreign func drwav_read_pcm_frames_s16 ( pWav: CPointer<drwav_drwav> , framesToRead: drwav_uint64_drwav_uint64 , pBufferOut: CPointer<drwav_int16_drwav_int16> ) : drwav_uint64_drwav_uint64

foreign func drwav_read_pcm_frames_s16le ( pWav: CPointer<drwav_drwav> , framesToRead: drwav_uint64_drwav_uint64 , pBufferOut: CPointer<drwav_int16_drwav_int16> ) : drwav_uint64_drwav_uint64

foreign func drwav_read_pcm_frames_s16be ( pWav: CPointer<drwav_drwav> , framesToRead: drwav_uint64_drwav_uint64 , pBufferOut: CPointer<drwav_int16_drwav_int16> ) : drwav_uint64_drwav_uint64

foreign func drwav_u8_to_s16 ( pOut: CPointer<drwav_int16_drwav_int16> , pIn: CString , sampleCount: UIntNative ) : Unit

foreign func drwav_s24_to_s16 ( pOut: CPointer<drwav_int16_drwav_int16> , pIn: CString , sampleCount: UIntNative ) : Unit

foreign func drwav_s32_to_s16 ( pOut: CPointer<drwav_int16_drwav_int16> , pIn: CPointer<drwav_int32_drwav_int32> , sampleCount: UIntNative ) : Unit

foreign func drwav_f32_to_s16 ( pOut: CPointer<drwav_int16_drwav_int16> , pIn: CPointer<Float32> , sampleCount: UIntNative ) : Unit

foreign func drwav_f64_to_s16 ( pOut: CPointer<drwav_int16_drwav_int16> , pIn: CPointer<Float64> , sampleCount: UIntNative ) : Unit

foreign func drwav_alaw_to_s16 ( pOut: CPointer<drwav_int16_drwav_int16> , pIn: CString , sampleCount: UIntNative ) : Unit

foreign func drwav_mulaw_to_s16 ( pOut: CPointer<drwav_int16_drwav_int16> , pIn: CString , sampleCount: UIntNative ) : Unit

foreign func drwav_read_pcm_frames_f32 ( pWav: CPointer<drwav_drwav> , framesToRead: drwav_uint64_drwav_uint64 , pBufferOut: CPointer<Float32> ) : drwav_uint64_drwav_uint64

foreign func drwav_read_pcm_frames_f32le ( pWav: CPointer<drwav_drwav> , framesToRead: drwav_uint64_drwav_uint64 , pBufferOut: CPointer<Float32> ) : drwav_uint64_drwav_uint64

foreign func drwav_read_pcm_frames_f32be ( pWav: CPointer<drwav_drwav> , framesToRead: drwav_uint64_drwav_uint64 , pBufferOut: CPointer<Float32> ) : drwav_uint64_drwav_uint64

foreign func drwav_u8_to_f32 ( pOut: CPointer<Float32> , pIn: CString , sampleCount: UIntNative ) : Unit

foreign func drwav_s16_to_f32 ( pOut: CPointer<Float32> , pIn: CPointer<drwav_int16_drwav_int16> , sampleCount: UIntNative ) : Unit

foreign func drwav_s24_to_f32 ( pOut: CPointer<Float32> , pIn: CString , sampleCount: UIntNative ) : Unit

foreign func drwav_s32_to_f32 ( pOut: CPointer<Float32> , pIn: CPointer<drwav_int32_drwav_int32> , sampleCount: UIntNative ) : Unit

foreign func drwav_f64_to_f32 ( pOut: CPointer<Float32> , pIn: CPointer<Float64> , sampleCount: UIntNative ) : Unit

foreign func drwav_alaw_to_f32 ( pOut: CPointer<Float32> , pIn: CString , sampleCount: UIntNative ) : Unit

foreign func drwav_mulaw_to_f32 ( pOut: CPointer<Float32> , pIn: CString , sampleCount: UIntNative ) : Unit

foreign func drwav_read_pcm_frames_s32 ( pWav: CPointer<drwav_drwav> , framesToRead: drwav_uint64_drwav_uint64 , pBufferOut: CPointer<drwav_int32_drwav_int32> ) : drwav_uint64_drwav_uint64

foreign func drwav_read_pcm_frames_s32le ( pWav: CPointer<drwav_drwav> , framesToRead: drwav_uint64_drwav_uint64 , pBufferOut: CPointer<drwav_int32_drwav_int32> ) : drwav_uint64_drwav_uint64

foreign func drwav_read_pcm_frames_s32be ( pWav: CPointer<drwav_drwav> , framesToRead: drwav_uint64_drwav_uint64 , pBufferOut: CPointer<drwav_int32_drwav_int32> ) : drwav_uint64_drwav_uint64

foreign func drwav_u8_to_s32 ( pOut: CPointer<drwav_int32_drwav_int32> , pIn: CString , sampleCount: UIntNative ) : Unit

foreign func drwav_s16_to_s32 ( pOut: CPointer<drwav_int32_drwav_int32> , pIn: CPointer<drwav_int16_drwav_int16> , sampleCount: UIntNative ) : Unit

foreign func drwav_s24_to_s32 ( pOut: CPointer<drwav_int32_drwav_int32> , pIn: CString , sampleCount: UIntNative ) : Unit

foreign func drwav_f32_to_s32 ( pOut: CPointer<drwav_int32_drwav_int32> , pIn: CPointer<Float32> , sampleCount: UIntNative ) : Unit

foreign func drwav_f64_to_s32 ( pOut: CPointer<drwav_int32_drwav_int32> , pIn: CPointer<Float64> , sampleCount: UIntNative ) : Unit

foreign func drwav_alaw_to_s32 ( pOut: CPointer<drwav_int32_drwav_int32> , pIn: CString , sampleCount: UIntNative ) : Unit

foreign func drwav_mulaw_to_s32 ( pOut: CPointer<drwav_int32_drwav_int32> , pIn: CString , sampleCount: UIntNative ) : Unit

foreign func drwav_init_file ( pWav: CPointer<drwav_drwav> , filename: CString , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_file_ex ( pWav: CPointer<drwav_drwav> , filename: CString , onChunk: drwav_chunk_proc_drwav_chunk_proc , pChunkUserData: CPointer<Unit> , flags: drwav_uint32_drwav_uint32 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_file_w ( pWav: CPointer<drwav_drwav> , filename: CPointer<wchar_t_wchar_t> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_file_ex_w ( pWav: CPointer<drwav_drwav> , filename: CPointer<wchar_t_wchar_t> , onChunk: drwav_chunk_proc_drwav_chunk_proc , pChunkUserData: CPointer<Unit> , flags: drwav_uint32_drwav_uint32 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_file_with_metadata ( pWav: CPointer<drwav_drwav> , filename: CString , flags: drwav_uint32_drwav_uint32 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_file_with_metadata_w ( pWav: CPointer<drwav_drwav> , filename: CPointer<wchar_t_wchar_t> , flags: drwav_uint32_drwav_uint32 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_file_write ( pWav: CPointer<drwav_drwav> , filename: CString , pFormat: CPointer<drwav_data_format_drwav_data_format> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_file_write_sequential ( pWav: CPointer<drwav_drwav> , filename: CString , pFormat: CPointer<drwav_data_format_drwav_data_format> , totalSampleCount: drwav_uint64_drwav_uint64 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_file_write_sequential_pcm_frames ( pWav: CPointer<drwav_drwav> , filename: CString , pFormat: CPointer<drwav_data_format_drwav_data_format> , totalPCMFrameCount: drwav_uint64_drwav_uint64 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_file_write_w ( pWav: CPointer<drwav_drwav> , filename: CPointer<wchar_t_wchar_t> , pFormat: CPointer<drwav_data_format_drwav_data_format> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_file_write_sequential_w ( pWav: CPointer<drwav_drwav> , filename: CPointer<wchar_t_wchar_t> , pFormat: CPointer<drwav_data_format_drwav_data_format> , totalSampleCount: drwav_uint64_drwav_uint64 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_file_write_sequential_pcm_frames_w ( pWav: CPointer<drwav_drwav> , filename: CPointer<wchar_t_wchar_t> , pFormat: CPointer<drwav_data_format_drwav_data_format> , totalPCMFrameCount: drwav_uint64_drwav_uint64 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_memory ( pWav: CPointer<drwav_drwav> , data: CPointer<Unit> , dataSize: UIntNative , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_memory_ex ( pWav: CPointer<drwav_drwav> , data: CPointer<Unit> , dataSize: UIntNative , onChunk: drwav_chunk_proc_drwav_chunk_proc , pChunkUserData: CPointer<Unit> , flags: drwav_uint32_drwav_uint32 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_memory_with_metadata ( pWav: CPointer<drwav_drwav> , data: CPointer<Unit> , dataSize: UIntNative , flags: drwav_uint32_drwav_uint32 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_memory_write ( pWav: CPointer<drwav_drwav> , ppData: CPointer<CPointer<Unit>> , pDataSize: CPointer<UIntNative> , pFormat: CPointer<drwav_data_format_drwav_data_format> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_memory_write_sequential ( pWav: CPointer<drwav_drwav> , ppData: CPointer<CPointer<Unit>> , pDataSize: CPointer<UIntNative> , pFormat: CPointer<drwav_data_format_drwav_data_format> , totalSampleCount: drwav_uint64_drwav_uint64 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_init_memory_write_sequential_pcm_frames ( pWav: CPointer<drwav_drwav> , ppData: CPointer<CPointer<Unit>> , pDataSize: CPointer<UIntNative> , pFormat: CPointer<drwav_data_format_drwav_data_format> , totalPCMFrameCount: drwav_uint64_drwav_uint64 , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : drwav_bool32_drwav_bool32

foreign func drwav_open_and_read_pcm_frames_s16 ( onRead: drwav_read_proc_drwav_read_proc , onSeek: drwav_seek_proc_drwav_seek_proc , onTell: drwav_tell_proc_drwav_tell_proc , pUserData: CPointer<Unit> , channelsOut: CPointer<UInt32> , sampleRateOut: CPointer<UInt32> , totalFrameCountOut: CPointer<drwav_uint64_drwav_uint64> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : CPointer<drwav_int16_drwav_int16>

foreign func drwav_open_and_read_pcm_frames_f32 ( onRead: drwav_read_proc_drwav_read_proc , onSeek: drwav_seek_proc_drwav_seek_proc , onTell: drwav_tell_proc_drwav_tell_proc , pUserData: CPointer<Unit> , channelsOut: CPointer<UInt32> , sampleRateOut: CPointer<UInt32> , totalFrameCountOut: CPointer<drwav_uint64_drwav_uint64> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : CPointer<Float32>

foreign func drwav_open_and_read_pcm_frames_s32 ( onRead: drwav_read_proc_drwav_read_proc , onSeek: drwav_seek_proc_drwav_seek_proc , onTell: drwav_tell_proc_drwav_tell_proc , pUserData: CPointer<Unit> , channelsOut: CPointer<UInt32> , sampleRateOut: CPointer<UInt32> , totalFrameCountOut: CPointer<drwav_uint64_drwav_uint64> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : CPointer<drwav_int32_drwav_int32>

foreign func drwav_open_file_and_read_pcm_frames_s16 ( filename: CString , channelsOut: CPointer<UInt32> , sampleRateOut: CPointer<UInt32> , totalFrameCountOut: CPointer<drwav_uint64_drwav_uint64> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : CPointer<drwav_int16_drwav_int16>

foreign func drwav_open_file_and_read_pcm_frames_f32 ( filename: CString , channelsOut: CPointer<UInt32> , sampleRateOut: CPointer<UInt32> , totalFrameCountOut: CPointer<drwav_uint64_drwav_uint64> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : CPointer<Float32>

foreign func drwav_open_file_and_read_pcm_frames_s32 ( filename: CString , channelsOut: CPointer<UInt32> , sampleRateOut: CPointer<UInt32> , totalFrameCountOut: CPointer<drwav_uint64_drwav_uint64> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : CPointer<drwav_int32_drwav_int32>

foreign func drwav_open_file_and_read_pcm_frames_s16_w ( filename: CPointer<wchar_t_wchar_t> , channelsOut: CPointer<UInt32> , sampleRateOut: CPointer<UInt32> , totalFrameCountOut: CPointer<drwav_uint64_drwav_uint64> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : CPointer<drwav_int16_drwav_int16>

foreign func drwav_open_file_and_read_pcm_frames_f32_w ( filename: CPointer<wchar_t_wchar_t> , channelsOut: CPointer<UInt32> , sampleRateOut: CPointer<UInt32> , totalFrameCountOut: CPointer<drwav_uint64_drwav_uint64> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : CPointer<Float32>

foreign func drwav_open_file_and_read_pcm_frames_s32_w ( filename: CPointer<wchar_t_wchar_t> , channelsOut: CPointer<UInt32> , sampleRateOut: CPointer<UInt32> , totalFrameCountOut: CPointer<drwav_uint64_drwav_uint64> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : CPointer<drwav_int32_drwav_int32>

foreign func drwav_open_memory_and_read_pcm_frames_s16 ( data: CPointer<Unit> , dataSize: UIntNative , channelsOut: CPointer<UInt32> , sampleRateOut: CPointer<UInt32> , totalFrameCountOut: CPointer<drwav_uint64_drwav_uint64> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : CPointer<drwav_int16_drwav_int16>

foreign func drwav_open_memory_and_read_pcm_frames_f32 ( data: CPointer<Unit> , dataSize: UIntNative , channelsOut: CPointer<UInt32> , sampleRateOut: CPointer<UInt32> , totalFrameCountOut: CPointer<drwav_uint64_drwav_uint64> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : CPointer<Float32>

foreign func drwav_open_memory_and_read_pcm_frames_s32 ( data: CPointer<Unit> , dataSize: UIntNative , channelsOut: CPointer<UInt32> , sampleRateOut: CPointer<UInt32> , totalFrameCountOut: CPointer<drwav_uint64_drwav_uint64> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : CPointer<drwav_int32_drwav_int32>

foreign func drwav_free ( p: CPointer<Unit> , pAllocationCallbacks: CPointer<drwav_allocation_callbacks_drwav_allocation_callbacks> ) : Unit

foreign func drwav_bytes_to_u16 ( data: CString ) : drwav_uint16_drwav_uint16

foreign func drwav_bytes_to_s16 ( data: CString ) : drwav_int16_drwav_int16

foreign func drwav_bytes_to_u32 ( data: CString ) : drwav_uint32_drwav_uint32

foreign func drwav_bytes_to_s32 ( data: CString ) : drwav_int32_drwav_int32

foreign func drwav_bytes_to_u64 ( data: CString ) : drwav_uint64_drwav_uint64

foreign func drwav_bytes_to_s64 ( data: CString ) : drwav_int64_drwav_int64

foreign func drwav_bytes_to_f32 ( data: CString ) : Float32

foreign func drwav_guid_equal ( a: CPointer<drwav_uint8_drwav_uint8> , b: CPointer<drwav_uint8_drwav_uint8> ) : drwav_bool32_drwav_bool32

foreign func drwav_fourcc_equal ( a: CString , b: CString ) : drwav_bool32_drwav_bool32

public type wchar_t_wchar_t = UInt16