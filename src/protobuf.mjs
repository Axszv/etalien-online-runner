export function encodeVarint(value) {
  let n = BigInt(value);
  const out = [];
  while (n >= 0x80n) {
    out.push(Number((n & 0x7fn) | 0x80n));
    n >>= 7n;
  }
  out.push(Number(n));
  return Uint8Array.from(out);
}

export function decodeVarint(bytes, offset) {
  let value = 0n;
  let shift = 0n;
  let index = offset;
  while (index < bytes.length) {
    const byte = bytes[index++];
    value |= BigInt(byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return { value, offset: index };
    shift += 7n;
    if (shift > 70n) throw new Error("protobuf varint is too long");
  }
  throw new Error("truncated protobuf varint");
}

export function parseFields(input) {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  const fields = [];
  let offset = 0;
  while (offset < bytes.length) {
    const tag = decodeVarint(bytes, offset);
    offset = tag.offset;
    const fieldNo = Number(tag.value >> 3n);
    const wireType = Number(tag.value & 7n);
    if (!fieldNo) throw new Error("invalid protobuf field number");
    if (wireType === 0) {
      const value = decodeVarint(bytes, offset);
      offset = value.offset;
      fields.push({ fieldNo, wireType, value: value.value });
    } else if (wireType === 1) {
      if (offset + 8 > bytes.length) throw new Error("truncated fixed64 field");
      fields.push({ fieldNo, wireType, value: bytes.slice(offset, offset + 8) });
      offset += 8;
    } else if (wireType === 2) {
      const length = decodeVarint(bytes, offset);
      offset = length.offset;
      const end = offset + Number(length.value);
      if (end > bytes.length) throw new Error("truncated length-delimited field");
      fields.push({ fieldNo, wireType, value: bytes.slice(offset, end) });
      offset = end;
    } else if (wireType === 5) {
      if (offset + 4 > bytes.length) throw new Error("truncated fixed32 field");
      fields.push({ fieldNo, wireType, value: bytes.slice(offset, offset + 4) });
      offset += 4;
    } else {
      throw new Error(`unsupported protobuf wire type ${wireType}`);
    }
  }
  return fields;
}

export function firstField(fields, fieldNo) {
  return fields.find((field) => field.fieldNo === fieldNo);
}

export function intField(fields, fieldNo, fallback = 0) {
  const field = firstField(fields, fieldNo);
  return field?.wireType === 0 ? Number(field.value) : fallback;
}

export function boolField(fields, fieldNo, fallback = false) {
  return intField(fields, fieldNo, fallback ? 1 : 0) !== 0;
}

export function stringField(fields, fieldNo, fallback = "") {
  const field = firstField(fields, fieldNo);
  if (field?.wireType !== 2) return fallback;
  return new TextDecoder().decode(field.value);
}

export function messageFields(fields, fieldNo) {
  return fields.filter((field) => field.fieldNo === fieldNo && field.wireType === 2)
    .map((field) => parseFields(field.value));
}

export function encodeStringField(fieldNo, value) {
  const bytes = new TextEncoder().encode(value);
  const tag = encodeVarint(BigInt((fieldNo << 3) | 2));
  const length = encodeVarint(BigInt(bytes.length));
  const out = new Uint8Array(tag.length + length.length + bytes.length);
  out.set(tag, 0);
  out.set(length, tag.length);
  out.set(bytes, tag.length + length.length);
  return out;
}

export function encodeIntField(fieldNo, value) {
  return concatBytes(
    encodeVarint(BigInt(fieldNo << 3)),
    encodeVarint(BigInt(value)),
  );
}

export function concatBytes(...chunks) {
  const out = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}
