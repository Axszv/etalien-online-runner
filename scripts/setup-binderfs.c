#include <errno.h>
#include <fcntl.h>
#include <linux/android/binderfs.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s BINDER_CONTROL DEVICE_NAME\n", argv[0]);
    return 2;
  }

  int control = open(argv[1], O_RDWR | O_CLOEXEC);
  if (control < 0) {
    perror("open binder-control");
    return 3;
  }

  struct binderfs_device device = {0};
  if (snprintf(device.name, sizeof(device.name), "%s", argv[2]) >=
      (int)sizeof(device.name)) {
    fprintf(stderr, "binder device name is too long: %s\n", argv[2]);
    close(control);
    return 4;
  }

  if (ioctl(control, BINDER_CTL_ADD, &device) < 0) {
    if (errno != EEXIST) {
      perror("BINDER_CTL_ADD");
      close(control);
      return 5;
    }
  }

  printf("created %s (%u:%u)\n", device.name, device.major, device.minor);
  close(control);
  return 0;
}
