export function escapeURI(value) {
	let result = '';
	for (let i = 0; i < length(value); i++) {
		let byte = ord(substr(value, i, 1));
		if ((byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || index('-._~', chr(byte)) >= 0)
			result += chr(byte);
		else result += sprintf('%%%02X', byte);
	}
	return result;
};
